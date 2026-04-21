#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKDIR="${WORKDIR:-/tmp/hybridtier-real-cxl-singletenant}"
BIN_PATH="${BIN_PATH:-${WORKDIR}/cxl_mem_access_probe}"
HOOK_SO="${HOOK_SO:-${WORKDIR}/hybridtier_singletenant_hook.so}"
CGROUP_ROOT="${CGROUP_ROOT:-/sys/fs/cgroup}"
CGROUP_NAME="${CGROUP_NAME:-hybridtier-singletenant-$$}"
CGROUP_PATH="${CGROUP_ROOT}/${CGROUP_NAME}"
CPUSET_CPUS="${CPUSET_CPUS:-0}"
CPUSET_MEMS="${CPUSET_MEMS:-0,2}"
CPU_NODE="${CPU_NODE:-0}"
CPU_ID="${CPU_ID:-0}"
MEM_NODE="${MEM_NODE:-2}"
FAST_NODE_ID="${FAST_NODE_ID:-0}"
FAST_TIER_SIZE_GB="${FAST_TIER_SIZE_GB:-1}"
WORKSET_MB="${WORKSET_MB:-768}"
DURATION_SECS="${DURATION_SECS:-12}"
STRIDE_BYTES="${STRIDE_BYTES:-64}"
PAGE_TYPE="${PAGE_TYPE:-regular}"
MEMORY_MAX="${MEMORY_MAX:-1536M}"
MEMCG_KSWAPD_DEMOTION_ENABLED="${MEMCG_KSWAPD_DEMOTION_ENABLED:-0}"
REQUIRE_MEMCG_NODE_BUDGET="${REQUIRE_MEMCG_NODE_BUDGET:-1}"
DISABLE_GLOBAL_NUMA_BALANCING="${DISABLE_GLOBAL_NUMA_BALANCING:-1}"
DISABLE_GLOBAL_DEMOTION="${DISABLE_GLOBAL_DEMOTION:-1}"
RUN_LOG="${WORKDIR}/singletenant.log"
MID_NUMA_STAT="${WORKDIR}/mid.memory.numa_stat"
MID_MEMORY_CURRENT="${WORKDIR}/mid.memory.current"
WORKLOAD_PID=""

ORIG_NUMA_BALANCING=""
ORIG_DEMOTION_ENABLED=""

log() {
  printf '%s\n' "$*"
}

section() {
  printf '\n== %s ==\n' "$*"
}

cleanup() {
  if [[ -n "${ORIG_NUMA_BALANCING}" && -w /proc/sys/kernel/numa_balancing ]]; then
    echo "${ORIG_NUMA_BALANCING}" > /proc/sys/kernel/numa_balancing || true
  fi
  if [[ -n "${ORIG_DEMOTION_ENABLED}" && -w /sys/kernel/mm/numa/demotion_enabled ]]; then
    echo "${ORIG_DEMOTION_ENABLED}" > /sys/kernel/mm/numa/demotion_enabled || true
  fi
  if [[ -d "${CGROUP_PATH}" ]]; then
    while IFS= read -r pid; do
      [[ -n "${pid}" ]] || continue
      echo "${pid}" > "${CGROUP_ROOT}/cgroup.procs" 2>/dev/null || true
    done < "${CGROUP_PATH}/cgroup.procs" 2>/dev/null || true
    rmdir "${CGROUP_PATH}" 2>/dev/null || true
  fi
}

trap cleanup EXIT

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log "run as root: sudo $0"
    exit 1
  fi
}

enable_controller_if_needed() {
  local controller="$1"
  if ! grep -qw "${controller}" "${CGROUP_ROOT}/cgroup.controllers"; then
    log "failed: controller ${controller} not available under ${CGROUP_ROOT}"
    exit 1
  fi
  if ! grep -qw "${controller}" "${CGROUP_ROOT}/cgroup.subtree_control"; then
    echo "+${controller}" > "${CGROUP_ROOT}/cgroup.subtree_control"
  fi
}

pick_knob_file() {
  local cg="$1"
  local name="$2"
  local path
  for path in "${cg}/${name}" "${cg}/memory.${name}"; do
    if [[ -e "${path}" ]]; then
      printf '%s\n' "${path}"
      return 0
    fi
  done
  return 1
}

write_knob() {
  local cg="$1"
  local name="$2"
  local value="$3"
  local path
  path="$(pick_knob_file "${cg}" "${name}")" || return 1
  printf '%s\n' "${value}" > "${path}"
}

ensure_node_online() {
  local size_mb
  size_mb="$(numactl -H | awk -v node="${MEM_NODE}" '$1 == "node" && $2 == node && $3 == "size:" { print $4 }')"
  if [[ -n "${size_mb}" && "${size_mb}" != "0" ]]; then
    return 0
  fi

  local memblock=""
  memblock="$(find "/sys/devices/system/node/node${MEM_NODE}" -maxdepth 1 -type l -name 'memory*' 2>/dev/null | sort | head -n 1 || true)"
  if [[ -z "${memblock}" ]]; then
    log "failed: node${MEM_NODE} has no memory blocks to online"
    exit 1
  fi

  echo online_movable > "${memblock}/state"
  log "[info] onlined ${memblock}"
}

build_helper() {
  mkdir -p "${WORKDIR}"
  gcc -O2 -g "${SCRIPT_DIR}/cxl_mem_access_probe.c" -o "${BIN_PATH}"
}

build_hook() {
  local page_define
  case "${PAGE_TYPE}" in
    regular) page_define="HYBRIDTIER_REGULAR" ;;
    huge) page_define="HYBRIDTIER_HUGE" ;;
    *)
      log "failed: PAGE_TYPE must be regular or huge"
      exit 1
      ;;
  esac

  g++ -shared -fPIC -g "${REPO_ROOT}/hook/hook.cpp" -o "${HOOK_SO}" -O2 \
    -ldl -lpthread -lnuma \
    -DFAST_MEMORY_SIZE_GB="${FAST_TIER_SIZE_GB}" \
    -DTARGET_EXE_NAME='"cxl_mem_access_probe"' \
    -D"${page_define}"
}

derive_capacity_pages() {
  local page_size
  page_size="$(getconf PAGESIZE 2>/dev/null || echo 4096)"
  printf '%s\n' "$((FAST_TIER_SIZE_GB * 1024 * 1024 * 1024 / page_size))"
}

configure_global_knobs() {
  if [[ "${DISABLE_GLOBAL_NUMA_BALANCING}" == "1" && -w /proc/sys/kernel/numa_balancing ]]; then
    ORIG_NUMA_BALANCING="$(< /proc/sys/kernel/numa_balancing)"
    echo 0 > /proc/sys/kernel/numa_balancing
  fi
  if [[ "${DISABLE_GLOBAL_DEMOTION}" == "1" && -w /sys/kernel/mm/numa/demotion_enabled ]]; then
    ORIG_DEMOTION_ENABLED="$(< /sys/kernel/mm/numa/demotion_enabled)"
    echo 0 > /sys/kernel/mm/numa/demotion_enabled
  fi
}

setup_cgroup() {
  local capacity_pages low_pages high_pages
  enable_controller_if_needed memory
  enable_controller_if_needed cpuset

  rmdir "${CGROUP_PATH}" 2>/dev/null || true
  mkdir -p "${CGROUP_PATH}"
  printf '%s\n' "${CPUSET_CPUS}" > "${CGROUP_PATH}/cpuset.cpus"
  printf '%s\n' "${CPUSET_MEMS}" > "${CGROUP_PATH}/cpuset.mems"
  printf '%s\n' "${MEMORY_MAX}" > "${CGROUP_PATH}/memory.max"
  printf 'max\n' > "${CGROUP_PATH}/memory.high"
  printf '0\n' > "${CGROUP_PATH}/memory.low"

  capacity_pages="$(derive_capacity_pages)"
  low_pages="$((capacity_pages * 90 / 100))"
  high_pages="$((capacity_pages * 95 / 100))"

  if write_knob "${CGROUP_PATH}" "node_capacity" "${FAST_NODE_ID} ${capacity_pages}"; then
    write_knob "${CGROUP_PATH}" "node_low_wmark" "${FAST_NODE_ID} ${low_pages}" || true
    write_knob "${CGROUP_PATH}" "node_high_wmark" "${FAST_NODE_ID} ${high_pages}" || true
    write_knob "${CGROUP_PATH}" "kswapd_demotion_enabled" "${MEMCG_KSWAPD_DEMOTION_ENABLED}" || true
  elif [[ "${REQUIRE_MEMCG_NODE_BUDGET}" == "1" ]]; then
    log "failed: memory.node_capacity knob not available in ${CGROUP_PATH}"
    exit 1
  else
    log "[warn] memory.node_capacity knob not available; runtime will fall back to physical node free memory"
  fi
}

dump_file() {
  local path="$1"
  if [[ -r "${path}" ]]; then
    log "--- ${path}"
    sed -n '1,20p' "${path}"
  fi
}

extract_field() {
  local field="$1"
  local file="$2"
  awk -v key="${field}" '{for (i=1; i<=NF; ++i) if ($i ~ ("^" key "=")) {split($i,a,"="); print a[2]}}' "${file}" | tail -n 1
}

launch_workload() {
  : > "${RUN_LOG}"
  (
    echo "${BASHPID}" > "${CGROUP_PATH}/cgroup.procs"
    export LD_PRELOAD="${HOOK_SO}"
    exec numactl --cpunodebind="${CPU_NODE}" --membind="${MEM_NODE}" \
      "${BIN_PATH}" \
        --cpu "${CPU_ID}" \
        --size-mb "${WORKSET_MB}" \
        --duration-sec "${DURATION_SECS}" \
        --stride "${STRIDE_BYTES}"
  ) > "${RUN_LOG}" 2>&1 &
  WORKLOAD_PID="$!"
}

require_root
build_helper
build_hook
ensure_node_online
configure_global_knobs
setup_cgroup

section "host"
log "kernel=$(uname -r)"
log "pmu_name=$(cat /sys/bus/event_source/devices/cpu/caps/pmu_name 2>/dev/null || echo unknown)"
numactl -H

section "cgroup"
dump_file "${CGROUP_PATH}/cpuset.cpus"
dump_file "${CGROUP_PATH}/cpuset.cpus.effective"
dump_file "${CGROUP_PATH}/cpuset.mems"
dump_file "${CGROUP_PATH}/cpuset.mems.effective"
dump_file "${CGROUP_PATH}/memory.max"
dump_file "${CGROUP_PATH}/memory.node_capacity"
dump_file "${CGROUP_PATH}/memory.node_low_wmark"
dump_file "${CGROUP_PATH}/memory.node_high_wmark"

section "launch"
launch_workload
log "pid=${WORKLOAD_PID}"
sleep 4
cp "${CGROUP_PATH}/memory.numa_stat" "${MID_NUMA_STAT}" 2>/dev/null || true
cat "${CGROUP_PATH}/memory.current" > "${MID_MEMORY_CURRENT}" 2>/dev/null || true
wait "${WORKLOAD_PID}"

section "mid-run"
dump_file "${MID_MEMORY_CURRENT}"
dump_file "${MID_NUMA_STAT}"

section "runtime-log"
sed -n '1,140p' "${RUN_LOG}"

section "validation"
if ! grep -Eq "Monitoring current cgroup|Cgroup-scoped runtime enabled" "${RUN_LOG}"; then
  log "failed: runtime did not enter cgroup-scoped mode"
  exit 1
fi
if ! grep -q "primary slow tier node is ${MEM_NODE}" "${RUN_LOG}"; then
  log "failed: runtime did not select node${MEM_NODE} as the slow tier"
  exit 1
fi
if ! grep -Eq "MEM_LOADS\(ldlat=3\)|REMOTE_CXL_MEM|REMOTE_DRAM" "${RUN_LOG}"; then
  log "failed: runtime did not print the slow-tier event selection"
  exit 1
fi
if ! grep -q "effective=1000" "${RUN_LOG}"; then
  log "failed: cgroup sample frequency clamp was not observed"
  exit 1
fi

HELPER_START_NODE="$(extract_field start_page_node "${RUN_LOG}")"
HELPER_END_NODE="$(extract_field end_page_node "${RUN_LOG}")"
if [[ "${HELPER_START_NODE}" != "${MEM_NODE}" ]]; then
  log "failed: helper pages did not start on node${MEM_NODE} (start_page_node=${HELPER_START_NODE})"
  exit 1
fi

MID_NODE_BYTES="$(grep -Eo "N${MEM_NODE}=[0-9]+" "${MID_NUMA_STAT}" 2>/dev/null | head -n 1 | cut -d= -f2 || true)"
MID_NODE_BYTES="${MID_NODE_BYTES:-0}"
if [[ "${MID_NODE_BYTES}" -eq 0 ]]; then
  log "failed: mid-run memory.numa_stat did not show node${MEM_NODE} usage"
  exit 1
fi

log "[ok] cgroup mode active, node${MEM_NODE} was used mid-run, helper start_page_node=${HELPER_START_NODE}, end_page_node=${HELPER_END_NODE}"

section "artifacts"
log "workdir=${WORKDIR}"
log "run_log=${RUN_LOG}"

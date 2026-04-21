#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-/tmp/hybrid_singletenant}"

WORKLOAD_SRC="${SCRIPT_DIR}/cxl_hotset_touch.c"
WORKLOAD_BIN="${BUILD_DIR}/cxl_hotset_touch"
HOOK_BIN="${BUILD_DIR}/hook.so"
LOG_PATH="${BUILD_DIR}/singletenant.log"
DURING_NUMA_STAT_PATH="${BUILD_DIR}/singletenant.during.numa_stat"

CGROUP_ROOT="${CGROUP_ROOT:-/sys/fs/cgroup}"
CGROUP_NAME="${CGROUP_NAME:-hybrid-single}"
CGROUP_PATH="${CGROUP_ROOT}/${CGROUP_NAME}"

FAST_NODE="${FAST_NODE:-0}"
SLOW_NODE="${SLOW_NODE:-2}"
CPU_NODE="${CPU_NODE:-0}"
CPUSET_CPUS="${CPUSET_CPUS:-0}"
CPUSET_MEMS="${CPUSET_MEMS:-0,2}"

FAST_TIER_SIZE_GB="${FAST_TIER_SIZE_GB:-1}"
NODE_CAPACITY_MB="${NODE_CAPACITY_MB:-256}"
NODE_LOW_WMARK_PCT="${NODE_LOW_WMARK_PCT:-90}"
NODE_HIGH_WMARK_PCT="${NODE_HIGH_WMARK_PCT:-95}"
MEMCG_KSWAPD_DEMOTION_ENABLED="${MEMCG_KSWAPD_DEMOTION_ENABLED:-0}"

ARENA_MB="${ARENA_MB:-768}"
HOT_MB="${HOT_MB:-64}"
PASSES="${PASSES:-1200}"
STRIDE_BYTES="${STRIDE_BYTES:-64}"
FINAL_SLEEP_MS="${FINAL_SLEEP_MS:-20000}"
OBSERVE_DELAY_SECS="${OBSERVE_DELAY_SECS:-10}"

HOOK_MODE="${HOOK_MODE:-regular}"
ONLINE_BLOCKS="${ONLINE_BLOCKS:-1}"
ONLINE_POLICY="${ONLINE_POLICY:-online_movable}"
RESTORE_ONLINE_BLOCKS="${RESTORE_ONLINE_BLOCKS:-1}"
SET_KERNEL_NUMA_KNOBS="${SET_KERNEL_NUMA_KNOBS:-1}"

ONLINED_BLOCKS=()
ORIG_NUMA_BALANCING=""
ORIG_DEMOTION_ENABLED=""
ORIG_ZONE_RECLAIM_MODE=""

log() {
  printf '%s\n' "$*"
}

as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "missing required command: $1"
    exit 1
  fi
}

enable_controller() {
  local ctl="$1"
  if [[ -r "${CGROUP_ROOT}/cgroup.controllers" ]] && grep -qw "${ctl}" "${CGROUP_ROOT}/cgroup.controllers"; then
    if ! grep -qw "${ctl}" "${CGROUP_ROOT}/cgroup.subtree_control"; then
      as_root sh -c "echo +${ctl} > '${CGROUP_ROOT}/cgroup.subtree_control'"
    fi
  fi
}

node_size_mb() {
  numactl -H | awk -v node="${SLOW_NODE}" '$1 == "node" && $2 == node && $3 == "size:" { print $4; exit }'
}

cleanup_online_blocks() {
  local block
  if [[ "${RESTORE_ONLINE_BLOCKS}" != "1" ]]; then
    return 0
  fi
  for block in "${ONLINED_BLOCKS[@]}"; do
    if [[ -e "${block}/state" ]]; then
      as_root sh -c "echo offline > '${block}/state'" || true
    fi
  done
}

ensure_slow_node_online() {
  local current_size
  local block
  local state
  local needed=0

  current_size="$(node_size_mb)"
  if [[ -n "${current_size}" && "${current_size}" != "0" ]]; then
    return 0
  fi

  while IFS= read -r block; do
    [[ -n "${block}" ]] || continue
    state="$(< "${block}/state")"
    if [[ "${state}" == "offline" ]]; then
      as_root sh -c "echo '${ONLINE_POLICY}' > '${block}/state'"
      ONLINED_BLOCKS+=("${block}")
      needed=$((needed + 1))
    fi
    if (( needed >= ONLINE_BLOCKS )); then
      break
    fi
  done < <(find "/sys/devices/system/node/node${SLOW_NODE}" -maxdepth 1 -type d -name 'memory*' | sort)

  sleep 1
  current_size="$(node_size_mb)"
  if [[ -z "${current_size}" || "${current_size}" == "0" ]]; then
    log "failed to online slow node${SLOW_NODE}"
    exit 1
  fi
}

restore_kernel_knobs() {
  if [[ -n "${ORIG_NUMA_BALANCING}" && -w /proc/sys/kernel/numa_balancing ]]; then
    as_root sh -c "echo '${ORIG_NUMA_BALANCING}' > /proc/sys/kernel/numa_balancing" || true
  fi
  if [[ -n "${ORIG_DEMOTION_ENABLED}" && -w /sys/kernel/mm/numa/demotion_enabled ]]; then
    as_root sh -c "echo '${ORIG_DEMOTION_ENABLED}' > /sys/kernel/mm/numa/demotion_enabled" || true
  fi
  if [[ -n "${ORIG_ZONE_RECLAIM_MODE}" && -w /proc/sys/vm/zone_reclaim_mode ]]; then
    as_root sh -c "echo '${ORIG_ZONE_RECLAIM_MODE}' > /proc/sys/vm/zone_reclaim_mode" || true
  fi
}

configure_kernel_knobs() {
  if [[ "${SET_KERNEL_NUMA_KNOBS}" != "1" ]]; then
    return 0
  fi

  if [[ -r /proc/sys/kernel/numa_balancing ]]; then
    ORIG_NUMA_BALANCING="$(< /proc/sys/kernel/numa_balancing)"
    as_root sh -c "echo 0 > /proc/sys/kernel/numa_balancing"
  fi
  if [[ -r /sys/kernel/mm/numa/demotion_enabled ]]; then
    ORIG_DEMOTION_ENABLED="$(< /sys/kernel/mm/numa/demotion_enabled)"
    as_root sh -c "echo 0 > /sys/kernel/mm/numa/demotion_enabled"
  fi
  if [[ -r /proc/sys/vm/zone_reclaim_mode ]]; then
    ORIG_ZONE_RECLAIM_MODE="$(< /proc/sys/vm/zone_reclaim_mode)"
    as_root sh -c "echo 0 > /proc/sys/vm/zone_reclaim_mode"
  fi
}

cleanup_cgroup() {
  local pid
  if [[ ! -d "${CGROUP_PATH}" ]]; then
    return 0
  fi
  if [[ -f "${CGROUP_PATH}/cgroup.procs" && -f "${CGROUP_ROOT}/cgroup.procs" ]]; then
    while IFS= read -r pid; do
      [[ -n "${pid}" ]] || continue
      as_root sh -c "echo '${pid}' > '${CGROUP_ROOT}/cgroup.procs'" || true
    done < "${CGROUP_PATH}/cgroup.procs"
  fi
  rmdir "${CGROUP_PATH}" 2>/dev/null || true
}

write_node_budget() {
  local page_size
  local capacity_pages
  local low_pages
  local high_pages

  page_size="$(getconf PAGESIZE 2>/dev/null || echo 4096)"
  capacity_pages=$((NODE_CAPACITY_MB * 1024 * 1024 / page_size))
  low_pages=$((capacity_pages * NODE_LOW_WMARK_PCT / 100))
  high_pages=$((capacity_pages * NODE_HIGH_WMARK_PCT / 100))

  if [[ ! -e "${CGROUP_PATH}/memory.node_capacity" ]]; then
    log "missing ${CGROUP_PATH}/memory.node_capacity"
    exit 1
  fi
  if [[ "${low_pages}" -gt "${high_pages}" || "${high_pages}" -gt "${capacity_pages}" ]]; then
    log "invalid node watermark percentages"
    exit 1
  fi

  as_root sh -c "printf '%s %s\n' '${FAST_NODE}' '${capacity_pages}' > '${CGROUP_PATH}/memory.node_capacity'"
  if [[ -e "${CGROUP_PATH}/memory.node_low_wmark" ]]; then
    as_root sh -c "printf '%s %s\n' '${FAST_NODE}' '${low_pages}' > '${CGROUP_PATH}/memory.node_low_wmark'"
  fi
  if [[ -e "${CGROUP_PATH}/memory.node_high_wmark" ]]; then
    as_root sh -c "printf '%s %s\n' '${FAST_NODE}' '${high_pages}' > '${CGROUP_PATH}/memory.node_high_wmark'"
  fi
  if [[ -e "${CGROUP_PATH}/memory.kswapd_demotion_enabled" ]]; then
    as_root sh -c "printf '%s\n' '${MEMCG_KSWAPD_DEMOTION_ENABLED}' > '${CGROUP_PATH}/memory.kswapd_demotion_enabled'"
  fi
}

build_binaries() {
  local page_macro

  mkdir -p "${BUILD_DIR}"
  cc -O2 -Wall -Wextra "${WORKLOAD_SRC}" -o "${WORKLOAD_BIN}"

  if [[ "${HOOK_MODE}" == "huge" ]]; then
    page_macro="HYBRIDTIER_HUGE"
  else
    page_macro="HYBRIDTIER_REGULAR"
  fi

  g++ -shared -fPIC -g "${REPO_ROOT}/hook/hook.cpp" -o "${HOOK_BIN}" -O2 \
    -ldl -lpthread -lnuma \
    "-DFAST_MEMORY_SIZE_GB=${FAST_TIER_SIZE_GB}" \
    "-DTARGET_EXE_NAME=\"$(basename "${WORKLOAD_BIN}")\"" \
    "-D${page_macro}"
}

dump_cgroup_state() {
  local path
  for path in \
    "${CGROUP_PATH}/cpuset.cpus.effective" \
    "${CGROUP_PATH}/cpuset.mems.effective" \
    "${CGROUP_PATH}/memory.current" \
    "${CGROUP_PATH}/memory.numa_stat" \
    "${CGROUP_PATH}/memory.node_capacity" \
    "${CGROUP_PATH}/memory.node_low_wmark" \
    "${CGROUP_PATH}/memory.node_high_wmark" \
    "${CGROUP_PATH}/memory.kswapd_demotion_enabled"; do
    if [[ -r "${path}" ]]; then
      log "--- ${path}"
      cat "${path}"
    fi
  done
}

extract_summary() {
  local runtime_ok=0
  local node2_seen=0

  if grep -Eq "slow tier node( is)? ${SLOW_NODE}" "${LOG_PATH}"; then
    runtime_ok=1
  fi
  if grep -E "final_node_sample .*node${SLOW_NODE}=[1-9]" "${LOG_PATH}" >/dev/null 2>&1; then
    node2_seen=1
  fi
  if [[ -r "${DURING_NUMA_STAT_PATH}" ]] && grep -E "N${SLOW_NODE}=[1-9]" "${DURING_NUMA_STAT_PATH}" >/dev/null 2>&1; then
    node2_seen=1
  fi
  if [[ -r "${CGROUP_PATH}/memory.numa_stat" ]] && grep -E "N${SLOW_NODE}=[1-9]" "${CGROUP_PATH}/memory.numa_stat" >/dev/null 2>&1; then
    node2_seen=1
  fi

  log "runtime_slow_node_detected=${runtime_ok}"
  log "slow_node_pages_observed=${node2_seen}"

  if [[ "${runtime_ok}" != "1" || "${node2_seen}" != "1" ]]; then
    log "single-tenant validation failed"
    return 1
  fi
  return 0
}

main() {
  trap 'restore_kernel_knobs; cleanup_cgroup; cleanup_online_blocks' EXIT

  require_cmd cc
  require_cmd g++
  require_cmd numactl

  enable_controller cpuset
  enable_controller memory
  ensure_slow_node_online
  configure_kernel_knobs
  build_binaries

  cleanup_cgroup
  as_root mkdir -p "${CGROUP_PATH}"
  as_root sh -c "printf '%s\n' '${CPUSET_CPUS}' > '${CGROUP_PATH}/cpuset.cpus'"
  as_root sh -c "printf '%s\n' '${CPUSET_MEMS}' > '${CGROUP_PATH}/cpuset.mems'"
  if [[ -e "${CGROUP_PATH}/memory.max" ]]; then
    as_root sh -c "printf '%s\n' 'max' > '${CGROUP_PATH}/memory.max'"
  fi
  if [[ -e "${CGROUP_PATH}/memory.high" ]]; then
    as_root sh -c "printf '%s\n' 'max' > '${CGROUP_PATH}/memory.high'"
  fi
  write_node_budget

  log "numactl topology before run:"
  numactl -H
  log "cgroup state before run:"
  dump_cgroup_state

  : > "${LOG_PATH}"
  rm -f "${DURING_NUMA_STAT_PATH}"

  as_root bash -lc "
    echo \$\$ > '${CGROUP_PATH}/cgroup.procs'
    export LD_PRELOAD='${HOOK_BIN}'
    exec numactl --cpunodebind='${CPU_NODE}' --preferred='${FAST_NODE}' \
      '${WORKLOAD_BIN}' '${ARENA_MB}' '${HOT_MB}' '${PASSES}' '${STRIDE_BYTES}' '${FINAL_SLEEP_MS}'
  " >"${LOG_PATH}" 2>&1 &
  WORK_PID=$!

  sleep "${OBSERVE_DELAY_SECS}"
  if kill -0 "${WORK_PID}" 2>/dev/null; then
    log "cgroup state during run:"
    dump_cgroup_state
    if [[ -r "${CGROUP_PATH}/memory.numa_stat" ]]; then
      cat "${CGROUP_PATH}/memory.numa_stat" > "${DURING_NUMA_STAT_PATH}"
    fi
  else
    log "workload exited before observe delay; continuing with final inspection"
  fi

  wait "${WORK_PID}"

  log "combined runtime/workload log:"
  sed -n '1,220p' "${LOG_PATH}"

  log "cgroup state after run:"
  dump_cgroup_state

  extract_summary
  log "single-tenant validation succeeded"
}

main "$@"

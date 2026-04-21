#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKLOAD_SRC="${SCRIPT_DIR}/cxl_stream_workload.c"
WORKLOAD_BIN="${WORKLOAD_BIN:-/tmp/cxl_stream_workload}"
HOOK_BIN="${HOOK_BIN:-/tmp/hybrid_singletenant_hook.so}"
CGROUP_ROOT="${CGROUP_ROOT:-/sys/fs/cgroup}"
CGROUP_NAME="${CGROUP_NAME:-hybrid-singletenant}"
CGROUP_PATH="${CGROUP_ROOT}/${CGROUP_NAME}"
CPU_LIST="${CPU_LIST:-0}"
CPU_ID="${CPU_ID:-0}"
FAST_NODE_ID="${FAST_NODE_ID:-0}"
SLOW_NODE_ID="${SLOW_NODE_ID:-2}"
CPUMEMS="${CPUMEMS:-0,2}"
FAST_TIER_SIZE_GB="${FAST_TIER_SIZE_GB:-1}"
MEMCG_CAPACITY_MB="${MEMCG_CAPACITY_MB:-1024}"
MEMCG_LOW_PCT="${MEMCG_LOW_PCT:-90}"
MEMCG_HIGH_PCT="${MEMCG_HIGH_PCT:-95}"
KSWAPD_MODE="${KSWAPD_MODE:-1}"
WORKLOAD_SIZE_MB="${WORKLOAD_SIZE_MB:-1536}"
WORKLOAD_DURATION_SEC="${WORKLOAD_DURATION_SEC:-20}"
WORKLOAD_SAMPLE_PAGES="${WORKLOAD_SAMPLE_PAGES:-1024}"
SAMPLE_BATCH_SIZE="${SAMPLE_BATCH_SIZE:-1024}"
AUTO_ONLINE_NODE="${AUTO_ONLINE_NODE:-1}"
LOG_DIR="${LOG_DIR:-/tmp/hybrid_singletenant_logs}"
LOG_PATH="${LOG_DIR}/runtime.log"
SNAPSHOT_PATH="${LOG_DIR}/memory.numa_stat"

log() {
  printf '%s\n' "$*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log "run as root (sudo)"
    exit 1
  fi
}

node_meminfo_kb() {
  local node="$1"
  local key="$2"
  awk -v key="$key" '$3 == key ":" {print $4; exit}' "/sys/devices/system/node/node${node}/meminfo"
}

online_next_section() {
  local node="$1"
  local section

  section="$(find "/sys/devices/system/node/node${node}" -maxdepth 1 -type l -name 'memory*' | sort | while read -r f; do
    local target state
    target="$(readlink -f "$f")"
    state="${target}/state"
    if [[ -r "${state}" ]] && [[ "$(<"${state}")" == "offline" ]]; then
      printf '%s\n' "${target}"
      break
    fi
  done)"
  if [[ -z "${section}" ]]; then
    return 1
  fi

  printf 'online_movable\n' > "${section}/state"
  log "[info] onlined $(basename "${section}") for node${node}"
}

ensure_node_capacity() {
  local node="$1"
  local want_kb="$2"
  local memtotal

  memtotal="$(node_meminfo_kb "${node}" MemTotal || echo 0)"
  while [[ -z "${memtotal}" || "${memtotal}" -lt "${want_kb}" ]]; do
    if [[ "${AUTO_ONLINE_NODE}" != "1" ]]; then
      log "[warn] node${node} has only ${memtotal:-0} kB online"
      return 1
    fi
    online_next_section "${node}" || return 1
    memtotal="$(node_meminfo_kb "${node}" MemTotal || echo 0)"
  done
  return 0
}

pick_knob_file() {
  local cg="$1"
  local name="$2"
  local f

  for f in "${cg}/${name}" "${cg}/memory.${name}"; do
    if [[ -f "${f}" ]]; then
      printf '%s\n' "${f}"
      return 0
    fi
  done
  return 1
}

write_knob() {
  local cg="$1"
  local name="$2"
  local value="$3"
  local f

  f="$(pick_knob_file "${cg}" "${name}")" || return 1
  printf '%s\n' "${value}" > "${f}"
}

cleanup() {
  local pid

  if [[ -n "${WORKLOAD_PID:-}" ]] && kill -0 "${WORKLOAD_PID}" 2>/dev/null; then
    kill "${WORKLOAD_PID}" 2>/dev/null || true
    wait "${WORKLOAD_PID}" 2>/dev/null || true
  fi

  if [[ -n "${MONITOR_PID:-}" ]] && kill -0 "${MONITOR_PID}" 2>/dev/null; then
    kill "${MONITOR_PID}" 2>/dev/null || true
    wait "${MONITOR_PID}" 2>/dev/null || true
  fi

  if [[ -d "${CGROUP_PATH}" ]]; then
    if [[ -f "${CGROUP_PATH}/cgroup.procs" ]]; then
      while read -r pid; do
        [[ -n "${pid}" ]] || continue
        printf '%s\n' "${pid}" > "${CGROUP_ROOT}/cgroup.procs" || true
      done < "${CGROUP_PATH}/cgroup.procs"
    fi
    rmdir "${CGROUP_PATH}" 2>/dev/null || true
  fi
}

monitor_cgroup() {
  local pid="$1"
  local seq=0

  while kill -0 "${pid}" 2>/dev/null; do
    if [[ -r "${CGROUP_PATH}/memory.numa_stat" ]]; then
      cat "${CGROUP_PATH}/memory.numa_stat" > "${LOG_DIR}/memory.numa_stat.${seq}"
      cp "${LOG_DIR}/memory.numa_stat.${seq}" "${SNAPSHOT_PATH}"
    fi
    if [[ -r "${CGROUP_PATH}/memory.current" ]]; then
      cat "${CGROUP_PATH}/memory.current" > "${LOG_DIR}/memory.current.${seq}"
    fi
    seq=$((seq + 1))
    sleep 1
  done
}

extract_node_count() {
  local phase="$1"
  local node="$2"
  awk -v phase="${phase}" -v key="N${node}" '
    $1 == "node_sample" {
      p = ""
      for (i = 1; i <= NF; ++i) {
        split($i, kv, "=")
        if (kv[1] == "phase") p = kv[2]
        if (p == phase && kv[1] == key) {
          print kv[2]
          exit
        }
      }
    }
  ' "${LOG_PATH}"
}

extract_max_pages_migrated() {
  awk '
    /pages migrated:/ {
      gsub(",", "", $3)
      if ($3 + 0 > max)
        max = $3 + 0
    }
    END {
      print max + 0
    }
  ' "${LOG_PATH}"
}

require_root
trap cleanup EXIT

mkdir -p "${LOG_DIR}"
rm -f "${LOG_PATH}" "${SNAPSHOT_PATH}"

ensure_node_capacity "${SLOW_NODE_ID}" $(((WORKLOAD_SIZE_MB + 1024) * 1024))

gcc -O2 -Wall -Wextra "${WORKLOAD_SRC}" -o "${WORKLOAD_BIN}" -lnuma
g++ -shared -fPIC -g "${REPO_ROOT}/hook/hook.cpp" -o "${HOOK_BIN}" -O2 \
  -ldl -lpthread -lnuma \
  -DFAST_MEMORY_SIZE_GB="${FAST_TIER_SIZE_GB}" \
  -DSAMPLE_BATCH_SIZE_DEF="${SAMPLE_BATCH_SIZE}" \
  -DTARGET_EXE_NAME='"cxl_stream_workload"' \
  -DHYBRIDTIER_REGULAR

grep -qw cpuset "${CGROUP_ROOT}/cgroup.subtree_control" || printf '+cpuset\n' > "${CGROUP_ROOT}/cgroup.subtree_control"
grep -qw memory "${CGROUP_ROOT}/cgroup.subtree_control" || printf '+memory\n' > "${CGROUP_ROOT}/cgroup.subtree_control"

rmdir "${CGROUP_PATH}" 2>/dev/null || true
mkdir -p "${CGROUP_PATH}"
printf '%s\n' "${CPU_LIST}" > "${CGROUP_PATH}/cpuset.cpus"
printf '%s\n' "${CPUMEMS}" > "${CGROUP_PATH}/cpuset.mems"
printf 'max\n' > "${CGROUP_PATH}/memory.max"
printf 'max\n' > "${CGROUP_PATH}/memory.high"
printf '0\n' > "${CGROUP_PATH}/memory.low"

page_size="$(getconf PAGESIZE)"
capacity_pages=$((MEMCG_CAPACITY_MB * 1024 * 1024 / page_size))
low_pages=$((capacity_pages * MEMCG_LOW_PCT / 100))
high_pages=$((capacity_pages * MEMCG_HIGH_PCT / 100))
write_knob "${CGROUP_PATH}" "node_capacity" "${FAST_NODE_ID} ${capacity_pages}"
write_knob "${CGROUP_PATH}" "node_low_wmark" "${FAST_NODE_ID} ${low_pages}"
write_knob "${CGROUP_PATH}" "node_high_wmark" "${FAST_NODE_ID} ${high_pages}"
write_knob "${CGROUP_PATH}" "kswapd_demotion_enabled" "${KSWAPD_MODE}"

log "[info] cgroup=${CGROUP_PATH} fast_node=${FAST_NODE_ID} slow_node=${SLOW_NODE_ID}"
log "[info] capacity_pages=${capacity_pages} low_pages=${low_pages} high_pages=${high_pages}"
log "[info] node2 MemTotal=$(node_meminfo_kb "${SLOW_NODE_ID}" MemTotal) kB MemFree=$(node_meminfo_kb "${SLOW_NODE_ID}" MemFree) kB"

bash -lc "echo \$$ > '${CGROUP_PATH}/cgroup.procs'; exec env LD_PRELOAD='${HOOK_BIN}' numactl --physcpubind='${CPU_ID}' '${WORKLOAD_BIN}' --cpu '${CPU_ID}' --alloc-node '${SLOW_NODE_ID}' --size-mb '${WORKLOAD_SIZE_MB}' --duration-sec '${WORKLOAD_DURATION_SEC}' --sample-pages '${WORKLOAD_SAMPLE_PAGES}'" \
  > "${LOG_PATH}" 2>&1 &
WORKLOAD_PID=$!

monitor_cgroup "${WORKLOAD_PID}" &
MONITOR_PID=$!

wait "${WORKLOAD_PID}"
wait "${MONITOR_PID}" || true

start_node2="$(extract_node_count start "${SLOW_NODE_ID}")"
end_node0="$(extract_node_count end "${FAST_NODE_ID}")"
end_node2="$(extract_node_count end "${SLOW_NODE_ID}")"
max_pages_migrated="$(extract_max_pages_migrated)"

log "[summary] start_node${SLOW_NODE_ID}=${start_node2:-0} end_node${FAST_NODE_ID}=${end_node0:-0} end_node${SLOW_NODE_ID}=${end_node2:-0} max_pages_migrated=${max_pages_migrated:-0}"
grep -E "Fast tier node is|slow-tier event=|Cgroup-scoped runtime enabled|node_sample phase=|stream_done" "${LOG_PATH}" || true
if [[ -f "${SNAPSHOT_PATH}" ]]; then
  log "[summary] latest memory.numa_stat snapshot"
  cat "${SNAPSHOT_PATH}"
fi

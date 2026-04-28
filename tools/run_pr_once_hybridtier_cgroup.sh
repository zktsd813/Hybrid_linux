#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

WORKDIR="${WORKDIR:-/tmp/hybridtier-pr-once}"
HOOK_SO="${HOOK_SO:-${WORKDIR}/hook.so}"
RUN_LOG="${RUN_LOG:-${WORKDIR}/pr.run.log}"
MID_NUMA="${MID_NUMA:-${WORKDIR}/pr.mid.memory.numa_stat}"
MID_CUR="${MID_CUR:-${WORKDIR}/pr.mid.memory.current}"
SAMPLES_DIR="${SAMPLES_DIR:-${WORKDIR}/samples}"
SUMMARY_TXT="${SUMMARY_TXT:-${WORKDIR}/summary.txt}"
TIMELINE_CSV="${TIMELINE_CSV:-${WORKDIR}/timeline.csv}"

CGROOT="${CGROOT:-/sys/fs/cgroup}"
CGNAME="${CGNAME:-hybridtier-pr-once-$$}"
CGPATH="${CGROOT}/${CGNAME}"

PR_BIN="${PR_BIN:-/Serverless/benchmark/gapbs/pr}"
NUMACTL_BIN="${NUMACTL_BIN:-/usr/bin/numactl}"
FAST_NODE="${FAST_NODE:-0}"
SLOW_NODE="${SLOW_NODE:-2}"
CPUSET_CPUS="${CPUSET_CPUS:-0-7}"
CPUSET_MEMS="${CPUSET_MEMS:-0,2}"
FAST_TIER_SIZE_GB="${FAST_TIER_SIZE_GB:-1}"
MEMORY_MAX="${MEMORY_MAX:-12G}"
MEMCG_KSWAPD_DEMOTION_ENABLED="${MEMCG_KSWAPD_DEMOTION_ENABLED:-0}"
MEM_POLICY="${MEM_POLICY:-bind_slow}"

OMP_THREADS="${OMP_THREADS:-8}"
PR_SCALE="${PR_SCALE:-24}"
PR_ITERS="${PR_ITERS:-2}"
PR_TRIALS="${PR_TRIALS:-1}"
PR_TOL="${PR_TOL:-1e-4}"
SNAPSHOT_DELAY_SECS="${SNAPSHOT_DELAY_SECS:-2}"
MONITOR_INTERVAL_SECS="${MONITOR_INTERVAL_SECS:-5}"

WORKLOAD_PID=""
ORIG_NUMA_BALANCING=""
ORIG_DEMOTION_ENABLED=""
ORIG_ZONE_RECLAIM_MODE=""
MAX_FAST_NODE_BYTES=0
MAX_SLOW_NODE_BYTES=0
MAX_TOTAL_BYTES=0
START_EPOCH_SECS=0

log() {
  printf '%s\n' "$*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log "run as root: sudo $0"
    exit 1
  fi
}

cleanup() {
  set +e
  if [[ -n "${WORKLOAD_PID}" ]] && kill -0 "${WORKLOAD_PID}" 2>/dev/null; then
    kill "${WORKLOAD_PID}" 2>/dev/null || true
    wait "${WORKLOAD_PID}" 2>/dev/null || true
  fi

  if [[ -n "${ORIG_NUMA_BALANCING}" && -w /proc/sys/kernel/numa_balancing ]]; then
    echo "${ORIG_NUMA_BALANCING}" > /proc/sys/kernel/numa_balancing || true
  fi
  if [[ -n "${ORIG_DEMOTION_ENABLED}" && -w /sys/kernel/mm/numa/demotion_enabled ]]; then
    echo "${ORIG_DEMOTION_ENABLED}" > /sys/kernel/mm/numa/demotion_enabled || true
  fi
  if [[ -n "${ORIG_ZONE_RECLAIM_MODE}" && -w /proc/sys/vm/zone_reclaim_mode ]]; then
    echo "${ORIG_ZONE_RECLAIM_MODE}" > /proc/sys/vm/zone_reclaim_mode || true
  fi

  if [[ -d "${CGPATH}" ]]; then
    while IFS= read -r pid; do
      [[ -n "${pid}" ]] || continue
      echo "${pid}" > "${CGROOT}/cgroup.procs" 2>/dev/null || true
    done < "${CGPATH}/cgroup.procs" 2>/dev/null || true
    rmdir "${CGPATH}" 2>/dev/null || true
  fi
}

trap cleanup EXIT

enable_controller() {
  local controller="$1"
  if grep -qw "${controller}" "${CGROOT}/cgroup.controllers" &&
     ! grep -qw "${controller}" "${CGROOT}/cgroup.subtree_control"; then
    echo "+${controller}" > "${CGROOT}/cgroup.subtree_control"
  fi
}

ensure_slow_node_online() {
  if "${NUMACTL_BIN}" -H | awk -v node="${SLOW_NODE}" '
    $1 == "node" && $2 == node && $3 == "size:" && $4 > 0 { found = 1 }
    END { exit(found ? 0 : 1) }'; then
    return 0
  fi

  log "node${SLOW_NODE} is offline; onlining memory blocks"
  while IFS= read -r block; do
    [[ -n "${block}" ]] || continue
    if [[ -r "${block}/state" ]] && [[ "$(< "${block}/state")" == "offline" ]]; then
      echo online_movable > "${block}/state"
    fi
  done < <(find "/sys/devices/system/node/node${SLOW_NODE}" -maxdepth 1 -name 'memory*' | sort)

  sleep 1
  if ! "${NUMACTL_BIN}" -H | awk -v node="${SLOW_NODE}" '
    $1 == "node" && $2 == node && $3 == "size:" && $4 > 0 { found = 1 }
    END { exit(found ? 0 : 1) }'; then
    log "slow node${SLOW_NODE} is still not online"
    exit 1
  fi
}

build_hook() {
  mkdir -p "${WORKDIR}"
  g++ -shared -fPIC -g "${REPO_ROOT}/hook/hook.cpp" -o "${HOOK_SO}" -O2 \
    -ldl -lpthread -lnuma \
    "-DFAST_MEMORY_SIZE_GB=${FAST_TIER_SIZE_GB}" \
    '-DTARGET_EXE_NAME="pr"' \
    -DHYBRIDTIER_REGULAR
}

configure_cgroup() {
  local page_size capacity_pages low_pages high_pages

  enable_controller memory
  enable_controller cpuset

  page_size="$(getconf PAGESIZE 2>/dev/null || echo 4096)"
  capacity_pages=$((FAST_TIER_SIZE_GB * 1024 * 1024 * 1024 / page_size))
  low_pages=$((capacity_pages * 90 / 100))
  high_pages=$((capacity_pages * 95 / 100))

  mkdir -p "${CGPATH}"
  echo "${CPUSET_CPUS}" > "${CGPATH}/cpuset.cpus"
  echo "${CPUSET_MEMS}" > "${CGPATH}/cpuset.mems"
  echo "${MEMORY_MAX}" > "${CGPATH}/memory.max"
  echo max > "${CGPATH}/memory.high"
  echo 0 > "${CGPATH}/memory.low"
  printf '%s %s\n' "${FAST_NODE}" "${capacity_pages}" > "${CGPATH}/memory.node_capacity"
  printf '%s %s\n' "${FAST_NODE}" "${low_pages}" > "${CGPATH}/memory.node_low_wmark"
  printf '%s %s\n' "${FAST_NODE}" "${high_pages}" > "${CGPATH}/memory.node_high_wmark"
  echo "${MEMCG_KSWAPD_DEMOTION_ENABLED}" > "${CGPATH}/memory.kswapd_demotion_enabled"
}

configure_kernel_knobs() {
  if [[ -r /proc/sys/kernel/numa_balancing ]]; then
    ORIG_NUMA_BALANCING="$(< /proc/sys/kernel/numa_balancing)"
    echo 0 > /proc/sys/kernel/numa_balancing
  fi
  if [[ -r /sys/kernel/mm/numa/demotion_enabled ]]; then
    ORIG_DEMOTION_ENABLED="$(< /sys/kernel/mm/numa/demotion_enabled)"
    echo 0 > /sys/kernel/mm/numa/demotion_enabled
  fi
  if [[ -r /proc/sys/vm/zone_reclaim_mode ]]; then
    ORIG_ZONE_RECLAIM_MODE="$(< /proc/sys/vm/zone_reclaim_mode)"
    echo 0 > /proc/sys/vm/zone_reclaim_mode
  fi
}

launch_workload() {
  local -a numactl_args
  : > "${RUN_LOG}"
  numactl_args=(--physcpubind="${CPUSET_CPUS}")
  case "${MEM_POLICY}" in
    bind_slow)
      numactl_args+=(--membind="${SLOW_NODE}")
      ;;
    localalloc)
      numactl_args+=(--localalloc)
      ;;
    default)
      ;;
    *)
      log "unsupported MEM_POLICY=${MEM_POLICY}"
      exit 1
      ;;
  esac
  (
    echo "${BASHPID}" > "${CGPATH}/cgroup.procs"
    export LD_PRELOAD="${HOOK_SO}"
    export OMP_NUM_THREADS="${OMP_THREADS}"
    export OMP_PROC_BIND=true
    export OMP_PLACES=cores
    exec "${NUMACTL_BIN}" "${numactl_args[@]}" \
      "${PR_BIN}" \
        "-g${PR_SCALE}" \
        "-i${PR_ITERS}" \
        "-n${PR_TRIALS}" \
        "-t${PR_TOL}"
  ) > "${RUN_LOG}" 2>&1 &
  WORKLOAD_PID="$!"
}

dump_file() {
  local path="$1"
  if [[ -r "${path}" ]]; then
    log "--- ${path}"
    sed -n '1,20p' "${path}"
  fi
}

extract_node_bytes() {
  local path="$1"
  local node="$2"
  awk -v node="N${node}" '
    {
      for (i = 1; i <= NF; ++i) {
        if ($i ~ ("^" node "=")) {
          split($i, kv, "=")
          print kv[2]
          exit
        }
      }
    }' "${path}" 2>/dev/null | tail -n 1
}

extract_total_bytes() {
  local path="$1"
  awk '
    {
      for (i = 2; i <= NF; ++i) {
        if ($i ~ /^N[0-9]+=/) {
          split($i, kv, "=")
          sum += kv[2]
        }
      }
    }
    END { print sum + 0 }' "${path}" 2>/dev/null
}

record_sample() {
  local tag="$1"
  local sample_path="${SAMPLES_DIR}/${tag}.memory.numa_stat"
  local fast_bytes slow_bytes total_bytes now elapsed over_limit fast_limit_bytes

  mkdir -p "${SAMPLES_DIR}"
  if ! cp "${CGPATH}/memory.numa_stat" "${sample_path}" 2>/dev/null; then
    return 0
  fi

  fast_bytes="$(extract_node_bytes "${sample_path}" "${FAST_NODE}")"
  slow_bytes="$(extract_node_bytes "${sample_path}" "${SLOW_NODE}")"
  total_bytes="$(extract_total_bytes "${sample_path}")"
  fast_bytes="${fast_bytes:-0}"
  slow_bytes="${slow_bytes:-0}"
  total_bytes="${total_bytes:-0}"

  if (( fast_bytes > MAX_FAST_NODE_BYTES )); then
    MAX_FAST_NODE_BYTES="${fast_bytes}"
  fi
  if (( slow_bytes > MAX_SLOW_NODE_BYTES )); then
    MAX_SLOW_NODE_BYTES="${slow_bytes}"
  fi
  if (( total_bytes > MAX_TOTAL_BYTES )); then
    MAX_TOTAL_BYTES="${total_bytes}"
  fi

  now="$(date +%s)"
  elapsed=$((now - START_EPOCH_SECS))
  fast_limit_bytes=$((FAST_TIER_SIZE_GB * 1024 * 1024 * 1024))
  if (( fast_bytes > fast_limit_bytes )); then
    over_limit=1
  else
    over_limit=0
  fi
  printf '%s,%s,%s,%s,%s,%s\n' \
    "${tag}" "${elapsed}" "${fast_bytes}" "${slow_bytes}" "${total_bytes}" "${over_limit}" \
    >> "${TIMELINE_CSV}"
}

monitor_workload() {
  local sample_idx=0
  while kill -0 "${WORKLOAD_PID}" 2>/dev/null; do
    record_sample "$(printf 'sample_%03d' "${sample_idx}")"
    sample_idx=$((sample_idx + 1))
    sleep "${MONITOR_INTERVAL_SECS}"
  done
}

require_root

if [[ ! -x "${PR_BIN}" ]]; then
  log "missing workload binary: ${PR_BIN}"
  exit 1
fi

build_hook
ensure_slow_node_online
configure_cgroup
configure_kernel_knobs
mkdir -p "${WORKDIR}" "${SAMPLES_DIR}"
START_EPOCH_SECS="$(date +%s)"
printf 'tag,elapsed_secs,fast_node_bytes,slow_node_bytes,total_bytes,over_fast_limit\n' > "${TIMELINE_CSV}"

log "== host =="
log "kernel=$(uname -r)"
log "pmu_name=$(cat /sys/bus/event_source/devices/cpu/caps/pmu_name 2>/dev/null || echo unknown)"
log "mem_policy=${MEM_POLICY}"
"${NUMACTL_BIN}" -H

log
log "== cgroup =="
dump_file "${CGPATH}/cpuset.cpus"
dump_file "${CGPATH}/cpuset.cpus.effective"
dump_file "${CGPATH}/cpuset.mems"
dump_file "${CGPATH}/cpuset.mems.effective"
dump_file "${CGPATH}/memory.max"
dump_file "${CGPATH}/memory.node_capacity"
dump_file "${CGPATH}/memory.node_low_wmark"
dump_file "${CGPATH}/memory.node_high_wmark"

log
log "== launch =="
launch_workload
log "pid=${WORKLOAD_PID}"
sleep "${SNAPSHOT_DELAY_SECS}"
cp "${CGPATH}/memory.numa_stat" "${MID_NUMA}" 2>/dev/null || true
cat "${CGPATH}/memory.current" > "${MID_CUR}" 2>/dev/null || true
record_sample "mid"
monitor_workload

wait "${WORKLOAD_PID}"
WORKLOAD_PID=""

log
log "== mid-run =="
dump_file "${MID_CUR}"
dump_file "${MID_NUMA}"

log
log "== runtime-log =="
sed -n '1,220p' "${RUN_LOG}"

grep -q "Fast tier node is ${FAST_NODE}, primary slow tier node is ${SLOW_NODE}" "${RUN_LOG}"
grep -q "Cgroup-scoped runtime enabled" "${RUN_LOG}"
grep -q "Using cgroup memory.node_capacity" "${RUN_LOG}"
grep -Eq "MEM_LOADS\\(ldlat=3\\)|REMOTE_CXL_MEM|REMOTE_DRAM" "${RUN_LOG}"
grep -Eq "N${SLOW_NODE}=[1-9]" "${MID_NUMA}"

{
  echo "fast_node=${FAST_NODE}"
  echo "slow_node=${SLOW_NODE}"
  echo "fast_tier_size_gb=${FAST_TIER_SIZE_GB}"
  echo "mem_policy=${MEM_POLICY}"
  echo "pr_scale=${PR_SCALE}"
  echo "max_fast_node_bytes=${MAX_FAST_NODE_BYTES}"
  echo "max_slow_node_bytes=${MAX_SLOW_NODE_BYTES}"
  echo "max_total_bytes=${MAX_TOTAL_BYTES}"
  echo "fast_limit_bytes=$((FAST_TIER_SIZE_GB * 1024 * 1024 * 1024))"
  echo "timeline_csv=${TIMELINE_CSV}"
} > "${SUMMARY_TXT}"

log
log "[ok] pr run completed with Hybrid_linux on node${SLOW_NODE}-backed cgroup"
log "artifacts:"
log "  hook=${HOOK_SO}"
log "  run_log=${RUN_LOG}"
log "  mid_numa=${MID_NUMA}"
log "  summary=${SUMMARY_TXT}"
log "  timeline=${TIMELINE_CSV}"

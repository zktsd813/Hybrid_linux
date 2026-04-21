#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-/tmp/hybrid_cxl_tools}"
PROBE_SRC="${SCRIPT_DIR}/cxl_pebs_probe.c"
PROBE_BIN="${BUILD_DIR}/cxl_pebs_probe"

CXL_NODE="${CXL_NODE:-2}"
CPU_NODE="${CPU_NODE:-0}"
CPU="${CPU:-0}"
SIZE_MB="${SIZE_MB:-256}"
SAMPLE_PERIOD="${SAMPLE_PERIOD:-1000}"
PASSES="${PASSES:-100}"
REMOTE_EVENT="${REMOTE_EVENT:-0x2d3}"
GENERIC_EVENT="${GENERIC_EVENT:-0x1cd}"
ONLINE_BLOCKS="${ONLINE_BLOCKS:-1}"
ONLINE_POLICY="${ONLINE_POLICY:-online_movable}"
RESTORE_ONLINE_BLOCKS="${RESTORE_ONLINE_BLOCKS:-1}"

ONLINED_BLOCKS=()

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

node_size_mb() {
  numactl -H | awk -v node="${CXL_NODE}" '$1 == "node" && $2 == node && $3 == "size:" { print $4; exit }'
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

ensure_cxl_node_online() {
  local current_size
  local needed
  local block
  local state

  current_size="$(node_size_mb)"
  if [[ -n "${current_size}" && "${current_size}" != "0" ]]; then
    return 0
  fi

  needed=0
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
  done < <(find "/sys/devices/system/node/node${CXL_NODE}" -maxdepth 1 -type d -name 'memory*' | sort)

  sleep 1
  current_size="$(node_size_mb)"
  if [[ -z "${current_size}" || "${current_size}" == "0" ]]; then
    log "failed to online node${CXL_NODE}; numactl still reports size=0"
    exit 1
  fi
}

build_probe() {
  mkdir -p "${BUILD_DIR}"
  cc -O2 -Wall -Wextra "${PROBE_SRC}" -lnuma -o "${PROBE_BIN}"
}

parse_field() {
  local line="$1"
  local key="$2"
  printf '%s\n' "${line}" | tr ' ' '\n' | awk -F= -v want="${key}" '$1 == want { print $2; exit }'
}

run_probe() {
  local label="$1"
  local event="$2"
  local line
  local first_page_node
  local samples
  local buffer_hits

  line="$(as_root numactl --cpunodebind="${CPU_NODE}" --membind="${CXL_NODE}" \
    "${PROBE_BIN}" "${event}" "${CPU}" "${CXL_NODE}" "${SIZE_MB}" "${SAMPLE_PERIOD}" "${PASSES}")"
  log "${label}: ${line}"

  first_page_node="$(parse_field "${line}" first_page_node)"
  samples="$(parse_field "${line}" samples)"
  buffer_hits="$(parse_field "${line}" buffer_hits)"

  if [[ "${first_page_node}" != "${CXL_NODE}" ]]; then
    log "${label}: first page is on node ${first_page_node}, expected node ${CXL_NODE}"
    return 1
  fi
  if [[ -z "${buffer_hits}" || "${buffer_hits}" == "0" ]]; then
    log "${label}: no sampled addresses landed inside the node${CXL_NODE} buffer"
    return 1
  fi
  if [[ -z "${samples}" || "${samples}" == "0" ]]; then
    log "${label}: no PEBS samples recorded"
    return 1
  fi
  return 0
}

main() {
  trap cleanup_online_blocks EXIT

  require_cmd cc
  require_cmd numactl

  log "kernel=$(uname -r)"
  if [[ -r /sys/bus/event_source/devices/cpu/caps/pmu_name ]]; then
    log "pmu=$(< /sys/bus/event_source/devices/cpu/caps/pmu_name)"
  fi
  if [[ -r /proc/sys/kernel/perf_event_paranoid ]]; then
    log "perf_event_paranoid=$(< /proc/sys/kernel/perf_event_paranoid)"
  fi

  ensure_cxl_node_online
  log "numactl topology after node${CXL_NODE} online:"
  numactl -H

  build_probe

  log "running explicit node${CXL_NODE} CXL PEBS checks with numactl --cpunodebind=${CPU_NODE} --membind=${CXL_NODE}"
  run_probe "remote_dram" "${REMOTE_EVENT}"
  run_probe "generic_mem_loads" "${GENERIC_EVENT}"

  log "summary: node${CXL_NODE} allocations are sampling successfully under numactl-fixed CXL access."
  log "note: compare remote_dram buffer_hits/sample density against generic_mem_loads before changing runtime defaults."
}

main "$@"

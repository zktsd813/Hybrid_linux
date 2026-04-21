#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${WORKDIR:-/tmp/hybridtier-real-cxl-pebs}"
BIN_PATH="${BIN_PATH:-${WORKDIR}/cxl_mem_access_probe}"
CPU_NODE="${CPU_NODE:-0}"
CPU_ID="${CPU_ID:-0}"
MEM_NODE="${MEM_NODE:-2}"
SIZE_MB="${SIZE_MB:-512}"
DURATION_SECS="${DURATION_SECS:-5}"
STRIDE_BYTES="${STRIDE_BYTES:-64}"
SAMPLE_PERIOD="${SAMPLE_PERIOD:-200}"
PMU_NAME="$(cat /sys/bus/event_source/devices/cpu/caps/pmu_name 2>/dev/null || echo unknown)"

log() {
  printf '%s\n' "$*"
}

section() {
  printf '\n== %s ==\n' "$*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log "run as root: sudo $0"
    exit 1
  fi
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

  if [[ -w "${memblock}/state" ]]; then
    echo online_movable > "${memblock}/state"
    log "[info] onlined ${memblock}"
  fi
}

build_probe() {
  mkdir -p "${WORKDIR}"
  gcc -O2 -g "${SCRIPT_DIR}/cxl_mem_access_probe.c" -o "${BIN_PATH}"
}

run_probe() {
  local label="$1"
  local raw_event="$2"
  local config1="$3"
  local log_path="${WORKDIR}/${label}.log"

  section "${label}"
  numactl --cpunodebind="${CPU_NODE}" --membind="${MEM_NODE}" \
    "${BIN_PATH}" \
      --cpu "${CPU_ID}" \
      --size-mb "${SIZE_MB}" \
      --duration-sec "${DURATION_SECS}" \
      --stride "${STRIDE_BYTES}" \
      --sample-event "${raw_event}" \
      --config1 "${config1}" \
      --sample-period "${SAMPLE_PERIOD}" | tee "${log_path}"

  local start_node end_node sample_count buffer_hits
  start_node="$(awk '{for (i=1; i<=NF; ++i) if ($i ~ /^start_page_node=/) {split($i,a,"="); print a[2]}}' "${log_path}")"
  end_node="$(awk '{for (i=1; i<=NF; ++i) if ($i ~ /^end_page_node=/) {split($i,a,"="); print a[2]}}' "${log_path}")"
  sample_count="$(awk '{for (i=1; i<=NF; ++i) if ($i ~ /^samples=/) {split($i,a,"="); print a[2]}}' "${log_path}")"
  buffer_hits="$(awk '{for (i=1; i<=NF; ++i) if ($i ~ /^buffer_hits=/) {split($i,a,"="); print a[2]}}' "${log_path}")"

  if [[ "${start_node}" != "${MEM_NODE}" ]]; then
    log "failed: ${label} started on node ${start_node}, expected ${MEM_NODE}"
    return 1
  fi
  if [[ "${end_node}" != "${MEM_NODE}" ]]; then
    log "warn: ${label} ended on node ${end_node}, expected ${MEM_NODE}"
  fi
  if [[ -z "${sample_count}" || "${sample_count}" -eq 0 ]]; then
    log "failed: ${label} captured no PEBS samples"
    return 1
  fi
  if [[ -z "${buffer_hits}" || "${buffer_hits}" -eq 0 ]]; then
    log "failed: ${label} captured no sample addresses inside the node${MEM_NODE} buffer"
    return 1
  fi

  log "[ok] ${label}: samples=${sample_count}, buffer_hits=${buffer_hits}, start_page_node=${start_node}"
}

require_root
build_probe
ensure_node_online

section "host"
log "kernel=$(uname -r)"
log "pmu_name=${PMU_NAME}"
numactl -H

section "events"
run_probe "mem_loads_ldlat3" "0x1cd" "3"
run_probe "remote_dram" "0x2d3" "0"

if [[ "${PMU_NAME}" == "granite_rapids" || "${PMU_NAME}" == "graniterapids" ]]; then
  run_probe "remote_cxl_mem" "0x10d3" "0"
fi

section "summary"
log "Primary validation passed: node${MEM_NODE} memory accesses generated PEBS sample addresses inside the bound buffer."
log "Logs are in ${WORKDIR}"

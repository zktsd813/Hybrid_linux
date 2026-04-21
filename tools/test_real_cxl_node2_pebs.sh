#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE_SRC="${SCRIPT_DIR}/pebs_numactl_probe.c"
PROBE_BIN="${PROBE_BIN:-/tmp/pebs_numactl_probe}"
CPU_BIND="${CPU_BIND:-0}"
MEM_NODE="${MEM_NODE:-2}"
SIZE_MB="${SIZE_MB:-512}"
SAMPLE_PERIOD="${SAMPLE_PERIOD:-4000}"
PASSES="${PASSES:-96}"
AUTO_ONLINE_NODE="${AUTO_ONLINE_NODE:-1}"
EVENTS="${EVENTS:-remote-dram mem-loads}"

log() {
  printf '%s\n' "$*"
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

  if [[ "${EUID}" -eq 0 ]]; then
    printf 'online_movable\n' > "${section}/state"
  else
    sudo sh -c "printf 'online_movable\n' > '${section}/state'"
  fi
  log "[info] onlined $(basename "${section}") for node${node}"
}

ensure_node_capacity() {
  local node="$1"
  local want_kb="$2"
  local memtotal

  memtotal="$(node_meminfo_kb "${node}" MemTotal || echo 0)"
  while [[ -z "${memtotal}" || "${memtotal}" -lt "${want_kb}" ]]; do
    if [[ "${AUTO_ONLINE_NODE}" != "1" ]]; then
      log "[warn] node${node} has only ${memtotal:-0} kB online; rerun with AUTO_ONLINE_NODE=1 or online memory manually."
      return 1
    fi
    online_next_section "${node}" || return 1
    memtotal="$(node_meminfo_kb "${node}" MemTotal || echo 0)"
  done
  return 0
}

extract_field() {
  local key="$1"
  local line="$2"
  awk -v key="${key}" '{
    for (i = 1; i <= NF; ++i) {
      split($i, kv, "=")
      if (kv[1] == key) {
        print kv[2]
        exit
      }
    }
  }' <<<"${line}"
}

main() {
  local require_kb
  local event

  require_kb=$(((SIZE_MB + 512) * 1024))
  ensure_node_capacity "${MEM_NODE}" "${require_kb}"

  gcc -O2 -Wall -Wextra "${PROBE_SRC}" -o "${PROBE_BIN}" -lnuma

  log "[info] PMU=$(< /sys/bus/event_source/devices/cpu/caps/pmu_name) perf_event_paranoid=$(< /proc/sys/kernel/perf_event_paranoid)"
  log "[info] numactl --physcpubind=${CPU_BIND} --membind=${MEM_NODE}"
  numactl -H | sed -n '1,20p'

  for event in ${EVENTS}; do
    local output event_line hits samples
    output="$(numactl --physcpubind="${CPU_BIND}" --membind="${MEM_NODE}" \
      "${PROBE_BIN}" "${event}" "${MEM_NODE}" "${SIZE_MB}" "${SAMPLE_PERIOD}" "${PASSES}")"
    event_line="$(awk '$1 ~ /^event=/' <<<"${output}")"
    log "${output}"
    hits="$(extract_field buffer_hits "${event_line}")"
    samples="$(extract_field samples "${event_line}")"
    log "[result] event=${event} samples=${samples:-0} buffer_hits=${hits:-0}"
  done
}

main "$@"

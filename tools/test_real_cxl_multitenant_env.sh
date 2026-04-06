#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CGROUP_ROOT="${CGROUP_ROOT:-/sys/fs/cgroup}"

log() {
  printf '%s\n' "$*"
}

section() {
  printf '\n== %s ==\n' "$*"
}

check_cmd() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    log "FOUND: $cmd -> $(command -v "$cmd")"
  else
    log "MISSING: $cmd"
  fi
}

dump_file() {
  local path="$1"
  if [ -r "$path" ]; then
    log "--- $path"
    sed -n '1,20p' "$path"
  else
    log "--- $path (missing or unreadable)"
  fi
}

dump_node_inventory() {
  if [ -d /sys/devices/system/node ]; then
    log "NUMA nodes:"
    find /sys/devices/system/node -maxdepth 1 -type d -name 'node*' | sort
  fi
}

dump_memory_tiering() {
  if [ -d /sys/devices/virtual/memory_tiering ]; then
    log "memory_tiering:"
    find /sys/devices/virtual/memory_tiering -maxdepth 2 -type f | sort | while read -r f; do
      dump_file "$f"
    done
  else
    log "memory_tiering: not present"
  fi
}

dump_cgroup_state() {
  local cg="$1"
  if [ ! -d "$cg" ]; then
    log "SKIP: $cg not found"
    return
  fi

  section "cgroup $(basename "$cg")"
  dump_file "$cg/cgroup.type"
  dump_file "$cg/cpuset.cpus"
  dump_file "$cg/cpuset.cpus.effective"
  dump_file "$cg/cpuset.mems"
  dump_file "$cg/cpuset.mems.effective"
  dump_file "$cg/memory.current"
  dump_file "$cg/memory.low"
  dump_file "$cg/memory.high"
  dump_file "$cg/memory.max"
  dump_file "$cg/memory.numa_stat"
  dump_file "$cg/memory.node_capacity"
  dump_file "$cg/memory.node_low_wmark"
  dump_file "$cg/memory.node_high_wmark"
  dump_file "$cg/memory.kswapd_demotion_enabled"
  dump_file "$cg/memory.reclaimd_state"
  dump_file "$cg/memory.numa_migrate_state"
  dump_file "$cg/memory.events"
  dump_file "$cg/memory.stat"
}

section "host"
dump_file /proc/cmdline
check_cmd uname
check_cmd lscpu
check_cmd numactl
check_cmd cxl
check_cmd daxctl
check_cmd perf

section "kernel"
uname -a
if command -v lscpu >/dev/null 2>&1; then
  lscpu | sed -n '1,40p'
fi

section "numa"
if command -v numactl >/dev/null 2>&1; then
  numactl -H
fi
dump_node_inventory

section "cgroup v2"
if [ -r "${CGROUP_ROOT}/cgroup.controllers" ]; then
  log "cgroup.controllers:"
  cat "${CGROUP_ROOT}/cgroup.controllers"
else
  log "cgroup.controllers: not readable at ${CGROUP_ROOT}"
fi
dump_file "${CGROUP_ROOT}/cgroup.subtree_control"
dump_file "${CGROUP_ROOT}/cgroup.procs"

section "cxl"
if command -v cxl >/dev/null 2>&1; then
  cxl list -M -D -R || true
else
  log "cxl command not available"
fi
if command -v daxctl >/dev/null 2>&1; then
  daxctl list -R -D || true
else
  log "daxctl command not available"
fi

section "perf"
if command -v perf >/dev/null 2>&1; then
  perf list 2>/dev/null | grep -nE "MEM_LOAD_L3_MISS_RETIRED|CXL|cxl_pmu" || true
else
  log "perf command not available"
fi

section "memory hotplug"
dump_file /sys/devices/system/memory/auto_online_blocks
dump_file /sys/kernel/mm/memory_hotplug/online_policy
dump_memory_tiering

section "tenant cgroups"
if [ "$#" -eq 0 ]; then
  log "No tenant cgroups passed. Re-run with one or more cgroup paths."
else
  for cg in "$@"; do
    dump_cgroup_state "$cg"
  done
fi

section "summary"
log "Repo root: ${REPO_ROOT}"
log "This script is read-only and does not modify any cgroup, node, or CXL state."

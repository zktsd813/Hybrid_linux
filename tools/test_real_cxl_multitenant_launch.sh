#!/bin/bash
set -euo pipefail

CGROUP_ROOT="${CGROUP_ROOT:-/sys/fs/cgroup}"
TENANT_SPECS="${TENANT_SPECS:-tenant-a|0-31|0|4G|/bin/true;tenant-b|0-31|1|4G|/bin/true}"
DRY_RUN="${DRY_RUN:-1}"
FAST_NODE_ID="${FAST_NODE_ID:-}"
MEMCG_FAST_TIER_SIZE_GB="${MEMCG_FAST_TIER_SIZE_GB:-}"
MEMCG_NODE_CAPACITY_PAGES="${MEMCG_NODE_CAPACITY_PAGES:-}"
MEMCG_NODE_LOW_WMARK_PAGES="${MEMCG_NODE_LOW_WMARK_PAGES:-}"
MEMCG_NODE_HIGH_WMARK_PAGES="${MEMCG_NODE_HIGH_WMARK_PAGES:-}"
MEMCG_KSWAPD_DEMOTION_ENABLED="${MEMCG_KSWAPD_DEMOTION_ENABLED:-}"

log() {
  printf '%s\n' "$*"
}

section() {
  printf '\n== %s ==\n' "$*"
}

emit() {
  printf 'DRY-RUN: %s\n' "$*"
}

resolve_memcg_capacity_pages() {
  local page_size
  if [ -n "${MEMCG_NODE_CAPACITY_PAGES}" ]; then
    printf '%s\n' "${MEMCG_NODE_CAPACITY_PAGES}"
    return 0
  fi
  if [ -z "${MEMCG_FAST_TIER_SIZE_GB}" ]; then
    return 0
  fi
  page_size=$(getconf PAGESIZE 2>/dev/null || echo 4096)
  printf '%s\n' $((MEMCG_FAST_TIER_SIZE_GB * 1024 * 1024 * 1024 / page_size))
}

normalize_spec() {
  local spec="$1"
  IFS='|' read -r name cpus mems memlimit command <<<"$spec"
  if [ -z "${name:-}" ] || [ -z "${cpus:-}" ] || [ -z "${mems:-}" ] || [ -z "${memlimit:-}" ]; then
    return 1
  fi
  if [ -z "${command:-}" ]; then
    command="/bin/true"
  fi
  printf '%s|%s|%s|%s|%s\n' "$name" "$cpus" "$mems" "$memlimit" "$command"
}

render_tenant() {
  local name="$1"
  local cpus="$2"
  local mems="$3"
  local memlimit="$4"
  local command="$5"
  local cgdir="${CGROUP_ROOT}/${name}"
  local capacity_pages low_pages high_pages

  section "tenant ${name}"
  emit "sudo mkdir -p '${cgdir}'"
  emit "printf '%s\n' '+memory +cpuset' | sudo tee '${CGROUP_ROOT}/cgroup.subtree_control'"
  emit "printf '%s\n' '${cpus}' | sudo tee '${cgdir}/cpuset.cpus'"
  emit "printf '%s\n' '${mems}' | sudo tee '${cgdir}/cpuset.mems'"
  emit "printf '%s\n' '${memlimit}' | sudo tee '${cgdir}/memory.max'"
  emit "printf '%s\n' '1G' | sudo tee '${cgdir}/memory.high'"
  emit "printf '%s\n' '0' | sudo tee '${cgdir}/memory.low'"
  if [ -n "${FAST_NODE_ID}" ]; then
    capacity_pages="$(resolve_memcg_capacity_pages)"
    if [ -n "${capacity_pages}" ]; then
      low_pages="${MEMCG_NODE_LOW_WMARK_PAGES:-$((capacity_pages * 90 / 100))}"
      high_pages="${MEMCG_NODE_HIGH_WMARK_PAGES:-$((capacity_pages * 95 / 100))}"
      emit "printf '%s %s\n' '${FAST_NODE_ID}' '${capacity_pages}' | sudo tee '${cgdir}/memory.node_capacity'"
      emit "printf '%s %s\n' '${FAST_NODE_ID}' '${low_pages}' | sudo tee '${cgdir}/memory.node_low_wmark'"
      emit "printf '%s %s\n' '${FAST_NODE_ID}' '${high_pages}' | sudo tee '${cgdir}/memory.node_high_wmark'"
      if [ -n "${MEMCG_KSWAPD_DEMOTION_ENABLED}" ]; then
        emit "printf '%s\n' '${MEMCG_KSWAPD_DEMOTION_ENABLED}' | sudo tee '${cgdir}/memory.kswapd_demotion_enabled'"
      fi
    fi
  fi
  emit "printf '%s\n' '<launcher-pid>' | sudo tee '${cgdir}/cgroup.procs'"
  emit "bash -lc 'echo \"attach workload to ${name} after moving the shell into ${cgdir}\"; exec ${command}'"
  emit "cat '${cgdir}/cpuset.cpus.effective'"
  emit "cat '${cgdir}/cpuset.mems.effective'"
  emit "cat '${cgdir}/memory.current'"
  emit "cat '${cgdir}/memory.numa_stat'"
  emit "cat '${cgdir}/memory.node_capacity'"
  emit "cat '${cgdir}/memory.node_low_wmark'"
  emit "cat '${cgdir}/memory.node_high_wmark'"
  emit "cat '${cgdir}/memory.reclaimd_state'"
}

section "input"
log "CGROUP_ROOT=${CGROUP_ROOT}"
log "DRY_RUN=${DRY_RUN}"
log "FAST_NODE_ID=${FAST_NODE_ID}"
log "MEMCG_FAST_TIER_SIZE_GB=${MEMCG_FAST_TIER_SIZE_GB}"

section "plan"
if [ -z "${TENANT_SPECS}" ]; then
  log "No tenant specs provided."
  exit 0
fi

printf '%s' "${TENANT_SPECS}" | tr ';' '\n' | while IFS= read -r raw_spec; do
  [ -z "${raw_spec}" ] && continue
  if normalized="$(normalize_spec "${raw_spec}")"; then
    IFS='|' read -r name cpus mems memlimit command <<<"${normalized}"
    render_tenant "$name" "$cpus" "$mems" "$memlimit" "$command"
  else
    log "Skipping invalid tenant spec: ${raw_spec}"
  fi
done

section "notes"
log "This script only prints the commands needed to create tenant cgroups and launch workloads."
log "The generated commands are not executed by this script."

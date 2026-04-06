#!/bin/bash

HYBRIDTIER_KERNEL_VER="6.2.0-hybridtier+"
AUTONUMA_KERNEL_VER="6.2.0-autonuma+"
TPP_KERNEL_VER="6.0.0+"
MULTICLOCK_KERNEL_VER="5.3.1-multiclock"
NO_NUMA_KERNEL_VER="6.2.0-hybridtier+"
DAMO_KERNEL_VER="5.19.17" 

PERF_EXE="/ssd1/songxin8/thesis/autonuma/linux-v6.2-autonuma/tools/perf/perf"
PERF_STAT_PID=

configure_optional_memcg_node_budget() {
  local fast_tier_size_gb="$1"
  local cgroup_path="${HYBRIDTIER_MEMCG_PATH:-}"
  local fast_node_id="${HYBRIDTIER_MEMCG_FAST_NODE:-}"
  local page_size capacity_pages low_pages high_pages kswapd_mode

  if [ -z "${cgroup_path}" ] || [ -z "${fast_node_id}" ]; then
    return 0
  fi

  if [ ! -d "${cgroup_path}" ]; then
    echo "[WARN] HYBRIDTIER_MEMCG_PATH does not exist: ${cgroup_path}. Skipping memcg node budget configuration."
    return 0
  fi

  if [ ! -e "${cgroup_path}/memory.node_capacity" ]; then
    echo "[INFO] memory.node_capacity is not available at ${cgroup_path}. Skipping memcg node budget configuration."
    return 0
  fi

  page_size=$(getconf PAGESIZE 2>/dev/null || echo 4096)
  capacity_pages="${HYBRIDTIER_MEMCG_NODE_CAPACITY_PAGES:-}"
  if [ -z "${capacity_pages}" ] && [ -n "${fast_tier_size_gb}" ] && [ "${fast_tier_size_gb}" != "0" ]; then
    capacity_pages=$((fast_tier_size_gb * 1024 * 1024 * 1024 / page_size))
  fi

  if [ -z "${capacity_pages}" ] || [ "${capacity_pages}" -le 0 ]; then
    echo "[WARN] No valid memcg node capacity could be derived. Set HYBRIDTIER_MEMCG_NODE_CAPACITY_PAGES or FAST_TIER_SIZE_GB."
    return 0
  fi

  low_pages="${HYBRIDTIER_MEMCG_NODE_LOW_WMARK_PAGES:-$((capacity_pages * 90 / 100))}"
  high_pages="${HYBRIDTIER_MEMCG_NODE_HIGH_WMARK_PAGES:-$((capacity_pages * 95 / 100))}"
  if [ "${low_pages}" -gt "${high_pages}" ] || [ "${high_pages}" -gt "${capacity_pages}" ]; then
    echo "[WARN] Invalid memcg watermark configuration: low=${low_pages}, high=${high_pages}, capacity=${capacity_pages}. Skipping."
    return 0
  fi

  echo "[INFO] Configuring memcg node budget at ${cgroup_path}: node=${fast_node_id}, capacity=${capacity_pages}, low=${low_pages}, high=${high_pages}"
  if [ -w "${cgroup_path}/memory.node_capacity" ]; then
    printf '%s %s\n' "${fast_node_id}" "${capacity_pages}" > "${cgroup_path}/memory.node_capacity"
  else
    echo "[WARN] ${cgroup_path}/memory.node_capacity is not writable. Skipping."
    return 0
  fi

  if [ -w "${cgroup_path}/memory.node_low_wmark" ]; then
    printf '%s %s\n' "${fast_node_id}" "${low_pages}" > "${cgroup_path}/memory.node_low_wmark"
  fi
  if [ -w "${cgroup_path}/memory.node_high_wmark" ]; then
    printf '%s %s\n' "${fast_node_id}" "${high_pages}" > "${cgroup_path}/memory.node_high_wmark"
  fi

  kswapd_mode="${HYBRIDTIER_MEMCG_KSWAPD_DEMOTION_ENABLED:-}"
  if [ -n "${kswapd_mode}" ] && [ -w "${cgroup_path}/memory.kswapd_demotion_enabled" ]; then
    printf '%s\n' "${kswapd_mode}" > "${cgroup_path}/memory.kswapd_demotion_enabled"
  fi
}

config_tiering_system() {
  TIERING_SYSTEM=$1
  if [ "$TIERING_SYSTEM" = "HYBRIDTIER" ]   ; then
    enable_hybridtier
  elif [ "$TIERING_SYSTEM" = "AUTONUMA" ]; then
    enable_autonuma "MGLRU"
  elif [ "$TIERING_SYSTEM" = "TPP" ]; then
    enable_tpp
  elif [ "$TIERING_SYSTEM" = "ARC" ]; then
    enable_hybridtier
  elif [ "$TIERING_SYSTEM" = "TWOQ" ]; then
    enable_hybridtier
  elif [ "$TIERING_SYSTEM" = "ALL_LOCAL" ]; then
    disable_numa
  else
    echo "ERROR: Invalid tiering system option $TIERING_SYSTEM"
    exit 1
  fi
}

run_bench () {
  WORKLOAD_SPECIFIC_CONFIG=$1
  BENCHMARK_COMMAND=$2
  EXE_NAME=$3
  TIERING_SYSTEM=$4
  FAST_TIER_SIZE_GB=$5
  PAGE_TYPE=$6 # regular or huge
  OUT_DIR=$7
  EXTRA_COMPILE_ARGS=$8

  clean_cache

  # Create name of log file
  LOGFILE_NAME=$(gen_file_name "$EXE_NAME" "$WORKLOAD_SPECIFIC_CONFIG" "${FAST_TIER_SIZE_GB}GB_${TIERING_SYSTEM}_${PAGE_TYPE}")

  if [ -z "$OUT_DIR" ]
  then
    echo "No output directory name provided. Using exp/${EXE_NAME}"
    LOGFILE_DIR="exp/${EXE_NAME}"
  else
    echo "Output directory name provided: exp/${OUT_DIR}"
    LOGFILE_DIR="exp/${OUT_DIR}"
  fi

  if [ -z "$EXTRA_COMPILE_ARGS" ]
  then
    echo "No extra compiler flags provided."
  else
    echo "Extra compiler flag provided: ${EXTRA_COMPILE_ARGS}"
  fi

  mkdir -p $LOGFILE_DIR
  LOGFILE="${LOGFILE_DIR}/${LOGFILE_NAME}"

  echo "=============================================="
  echo "============== Running benchmark $EXE_NAME"
  echo "=============================================="
  echo "Fast tier size: $FAST_TIER_SIZE_GB GB"
  echo "Tiering system: $TIERING_SYSTEM"
  echo "Log file: $LOGFILE"

  echo "===== Tiering system configuration"
  config_tiering_system $TIERING_SYSTEM
  echo "===== Tiering system configuration end"
  configure_optional_memcg_node_budget "${FAST_TIER_SIZE_GB}"

  write_frontmatter $LOGFILE
  start_perf_stat 10000 $LOGFILE

  # HybridTier runtime code
  HOOK_DIR="${BIGMEMBENCH_COMMON_PATH}/hook"
  HOOK_SO="${HOOK_DIR}/hook.so"

  if [[ "$TIERING_SYSTEM" == "HYBRIDTIER" ]]; then
    pushd $HOOK_DIR > /dev/null

    # HybridTier has different runtime implementation for regular and huge page
    if [[ "$PAGE_TYPE" == "regular" ]]; then
      DPAGE_TYPE="HYBRIDTIER_REGULAR"
    elif [[ "$PAGE_TYPE" == "huge" ]]; then
      DPAGE_TYPE="HYBRIDTIER_HUGE"
    fi 

    echo "g++ -shared -fPIC -g hook.cpp -o hook.so -O3 \
        -ldl -lpthread -lnuma \
        -DFAST_MEMORY_SIZE_GB=${FAST_TIER_SIZE_GB} \
        -DTARGET_EXE_NAME=\"${EXE_NAME}\" \
        -D${DPAGE_TYPE} ${EXTRA_COMPILE_ARGS}"

    g++ -shared -fPIC -g hook.cpp -o hook.so -O3 \
        -ldl -lpthread -lnuma \
        -DFAST_MEMORY_SIZE_GB=${FAST_TIER_SIZE_GB} \
        -DTARGET_EXE_NAME=\"${EXE_NAME}\" \
        -D${DPAGE_TYPE} ${EXTRA_COMPILE_ARGS}

    popd > /dev/null
    export LD_PRELOAD=${HOOK_SO}
  elif [[ "$TIERING_SYSTEM" == "ARC" ]]; then
    # ARC only supports regular page
    echo "Compiling ARC runtime"
    pushd $HOOK_DIR > /dev/null
    g++ -shared -fPIC -g hook.cpp -o hook.so -O3 \
        -ldl -lpthread -lnuma \
        -DFAST_MEMORY_SIZE_GB=${FAST_TIER_SIZE_GB} \
        -DTARGET_EXE_NAME=\"${EXE_NAME}\" \
        -DARC_TIERING

    popd > /dev/null
    export LD_PRELOAD=${HOOK_SO}
  elif [[ "$TIERING_SYSTEM" == "TWOQ" ]]; then
    echo "Compiling TwoQ runtime"
    pushd $HOOK_DIR > /dev/null
    g++ -shared -fPIC -g hook.cpp -o hook.so -O3 \
        -ldl -lpthread -lnuma \
        -DFAST_MEMORY_SIZE_GB=${FAST_TIER_SIZE_GB} \
        -DTARGET_EXE_NAME=\"${EXE_NAME}\" \
        -DTWOQ_TIERING

    popd > /dev/null
    export LD_PRELOAD=${HOOK_SO}
  else export LD_PRELOAD=
  fi

  COMMAND_PREFIX=$(get_cmd_prefix $TIERING_SYSTEM)
  echo "Full benchmark command: ${COMMAND_PREFIX} ${BENCHMARK_COMMAND} &>> $LOGFILE"
  echo "Waiting for benchmark to finish..."
  eval "${COMMAND_PREFIX} ${BENCHMARK_COMMAND} &>> $LOGFILE"

  export LD_PRELOAD=

  write_backmatter $LOGFILE
  kill_perf_stat
}


clean_cache () { 
  sync
  echo "Clearing caches..."
  # clean CPU caches
  ${BIGMEMBENCH_COMMON_PATH}/tools/clear_cpu_cache
  #./tools/clear_cpu_cache
  # clean page cache
  echo 3 > /proc/sys/vm/drop_caches
}

enable_multiclock () {
  # check Linux kernel version
  KERNEL_VER=$(uname -r)
  if [ "$KERNEL_VER" != "$MULTICLOCK_KERNEL_VER" ] ; then
    echo "ERROR! Expecting kernel version $MULTICLOCK_KERNEL_VER to evaluate Multi-clock, but $KERNEL_VER detected."
    echo "The expected kernel version is defined as TPP_KERNEL_VER in ${BIGMEMBENCH_COMMON_PATH}/run_exp_common.sh"
    exit 1
  fi

  # check kernel parameters
  # numad will override autoNUMA, so stop it
  sudo service numad stop
  echo 15 > /proc/sys/vm/zone_reclaim_mode
  echo 1 > /proc/sys/kernel/numa_balancing

  NUMAD_OUT=$(systemctl is-active numad)
  ZONE_RECLAIM_MODE=$(cat /proc/sys/vm/zone_reclaim_mode)
  NUMA_BALANCING=$(cat /proc/sys/kernel/numa_balancing)

  if [ "$ZONE_RECLAIM_MODE" != "15" ] \
  || [ "$NUMA_BALANCING" != "1" ] \
  || [ "$NUMAD_OUT" != "inactive" ] ; then
    echo "ERROR! Enable MULTI-CLOCK kernel parameter configuration failed."
    echo "numad service status: $NUMAD_OUT (inactive)"
    echo "/proc/sys/vm/zone_reclaim_mode: $ZONE_RECLAIM_MODE (15)"
    echo "/proc/sys/kernel/numa_balancing: $NUMA_BALANCING (1)"
    exit 1
  fi

  echo "Multi-clock setup successful."
}

enable_damo () {
  # check Linux kernel version
  KERNEL_VER=$(uname -r)
  if [ "$KERNEL_VER" != "$DAMO_KERNEL_VER" ] ; then
    echo "ERROR! Expecting kernel version $DAMO_KERNEL_VER to evaluate solutions that has Linux NUMA disabled, but $KERNEL_VER detected."
    echo "The expected kernel version is defined as DAMO_KERNEL_VER in ${BIGMEMBENCH_COMMON_PATH}/run_exp_common.sh"
    exit 1
  fi

  # Disable AutoNUMA and let DAMO perform tiering management
  # check kernel parameters
  sudo service numad stop
  echo 0 > /proc/sys/vm/zone_reclaim_mode
  echo 0 > /proc/sys/kernel/numa_balancing
  echo 0 > /sys/kernel/mm/numa/demotion_enabled

  NUMAD_OUT=$(systemctl is-active numad)
  ZONE_RECLAIM_MODE=$(cat /proc/sys/vm/zone_reclaim_mode)
  NUMA_BALANCING=$(cat /proc/sys/kernel/numa_balancing)
  DEMOTION_ENABLED=$(cat /sys/kernel/mm/numa/demotion_enabled)

  if [ "$ZONE_RECLAIM_MODE" != "0" ] \
  || [ "$NUMA_BALANCING" != "0" ] \
  || [ "$DEMOTION_ENABLED" != "false" ] \
  || [ "$NUMAD_OUT" != "inactive" ] ; then
    echo "ERROR! DAMO kernel parameter configuration failed."
    echo "numad service status: $NUMAD_OUT (inactive)"
    echo "/proc/sys/vm/zone_reclaim_mode: $ZONE_RECLAIM_MODE (0)"
    echo "/proc/sys/kernel/numa_balancing: $NUMA_BALANCING (0)"
    echo "/sys/kernel/mm/numa/demotion_enabled: $DEMOTION_ENABLED (0)"
    exit 1
  fi

  echo "numad service status: $NUMAD_OUT (inactive)"
  echo "/proc/sys/vm/zone_reclaim_mode: $ZONE_RECLAIM_MODE (0)"
  echo "/proc/sys/kernel/numa_balancing: $NUMA_BALANCING (0)"
  echo "/sys/kernel/mm/numa/demotion_enabled: $DEMOTION_ENABLED (0)"

  echo "DAMO setup successful."
}



enable_tpp () {
  # check Linux kernel version
  KERNEL_VER=$(uname -r)
  if [ "$KERNEL_VER" != "$TPP_KERNEL_VER" ] ; then
    echo "ERROR! Expecting kernel version $TPP_KERNEL_VER to evaluate TPP, but $KERNEL_VER detected."
    echo "The expected kernel version is defined as TPP_KERNEL_VER in ${BIGMEMBENCH_COMMON_PATH}/run_exp_common.sh"
    exit 1
  fi

  # check kernel parameters
  # numad will override autoNUMA, so stop it
  sudo service numad stop
  echo 15 > /proc/sys/vm/zone_reclaim_mode
  echo 2 > /proc/sys/kernel/numa_balancing
  echo 1 > /sys/kernel/mm/numa/demotion_enabled
  echo 200 > /proc/sys/vm/watermark_scale_factor

  NUMAD_OUT=$(systemctl is-active numad)
  ZONE_RECLAIM_MODE=$(cat /proc/sys/vm/zone_reclaim_mode)
  NUMA_BALANCING=$(cat /proc/sys/kernel/numa_balancing)
  DEMOTION_ENABLED=$(cat /sys/kernel/mm/numa/demotion_enabled)
  WATERMARK_SCALE_FACTOR=$(cat /proc/sys/vm/watermark_scale_factor)

  if [ "$ZONE_RECLAIM_MODE" != "15" ] \
  || [ "$NUMA_BALANCING" != "2" ] \
  || [ "$DEMOTION_ENABLED" != "true" ] \
  || [ "$WATERMARK_SCALE_FACTOR" != "200" ] \
  || [ "$NUMAD_OUT" != "inactive" ] ; then
    echo "ERROR! Enable TPP kernel parameter configuration failed."
    echo "numad service status: $NUMAD_OUT (inactive)"
    echo "/proc/sys/vm/zone_reclaim_mode: $ZONE_RECLAIM_MODE (15)"
    echo "/proc/sys/kernel/numa_balancing: $NUMA_BALANCING (2)"
    echo "/sys/kernel/mm/numa/demotion_enabled: $DEMOTION_ENABLED (1)"
    echo "/proc/sys/vm/watermark_scale_factor: $WATERMARK_SCALE_FACTOR (200)"
    exit 1
  fi

  echo "TPP setup successful."
  echo "numad service status: $NUMAD_OUT (inactive)"
  echo "/proc/sys/vm/zone_reclaim_mode: $ZONE_RECLAIM_MODE (15)"
  echo "/proc/sys/kernel/numa_balancing: $NUMA_BALANCING (2)"
  echo "/sys/kernel/mm/numa/demotion_enabled: $DEMOTION_ENABLED (1)"
  echo "/proc/sys/vm/watermark_scale_factor: $WATERMARK_SCALE_FACTOR (200)"
}

enable_autonuma () {
  # check Linux kernel version
  KERNEL_VER=$(uname -r)
  if [ "$KERNEL_VER" != "$AUTONUMA_KERNEL_VER" ] ; then
    echo "ERROR! Expecting kernel version $AUTONUMA_KERNEL_VER to evaluate AutoNUMA, but $KERNEL_VER detected."
    echo "The expected kernel version is defined as AUTONUMA_KERNEL_VER in ${BIGMEMBENCH_COMMON_PATH}/run_exp_common.sh"
    exit 1
  fi

  autonuma_option=$1
  if [ -z $autonuma_option ]; then
    echo "ERROR: No AutoNUMA option provided."
    exit 1
  fi
  if [ $autonuma_option = "LRU" ]; then
    echo "Using AutoNUMA LRU demotion"
    MGLRU_VAL="0x0000"
  elif [ $autonuma_option = "MGLRU" ]; then
    echo "Using AutoNUMA MGLRU demotion"
    MGLRU_VAL="0x0007"
  else
    echo "ERROR: Invalid AutoNUMA option $autonuma_option"
    exit 1
  fi

  # check kernel parameters
  # numad will override autoNUMA, so stop it
  sudo service numad stop
  echo 15 > /proc/sys/vm/zone_reclaim_mode
  echo 2 > /proc/sys/kernel/numa_balancing
  echo 1 > /sys/kernel/mm/numa/demotion_enabled
  echo 200 > /proc/sys/vm/watermark_scale_factor
  # Microbenchmark shows 34GB/s read-only cross socket BW. I am assuming write BW is the same.
  # According to kernel docs, this value should be set to less than 1/10 of the write BW, hence 3400MB/s.
  echo 3400 > /proc/sys/kernel/numa_balancing_promote_rate_limit_MBps
  echo $MGLRU_VAL > /sys/kernel/mm/lru_gen/enabled

  NUMAD_OUT=$(systemctl is-active numad)
  ZONE_RECLAIM_MODE=$(cat /proc/sys/vm/zone_reclaim_mode)
  NUMA_BALANCING=$(cat /proc/sys/kernel/numa_balancing)
  DEMOTION_ENABLED=$(cat /sys/kernel/mm/numa/demotion_enabled)
  WATERMARK_SCALE_FACTOR=$(cat /proc/sys/vm/watermark_scale_factor)
  NUMA_BALANCING_PROMOTE_RATE_LIMIT_MBPS=$(cat /proc/sys/kernel/numa_balancing_promote_rate_limit_MBps)
  MGLRU_ENABLED=$(cat /sys/kernel/mm/lru_gen/enabled)

  if [ "$ZONE_RECLAIM_MODE" != "15" ] \
  || [ "$NUMA_BALANCING" != "2" ] \
  || [ "$DEMOTION_ENABLED" != "true" ] \
  || [ "$NUMA_BALANCING_PROMOTE_RATE_LIMIT_MBPS" != "3400" ] \
  || [ "$MGLRU_ENABLED" != $MGLRU_VAL ] \
  || [ "$WATERMARK_SCALE_FACTOR" != "200" ] \
  || [ "$NUMAD_OUT" != "inactive" ] ; then
    echo "ERROR! Enable AutoNUMA kernel parameter configuration failed."
    echo "numad service status: $NUMAD_OUT (inactive)"
    echo "/proc/sys/vm/zone_reclaim_mode: $ZONE_RECLAIM_MODE (15)"
    echo "/proc/sys/kernel/numa_balancing: $NUMA_BALANCING (2)"
    echo "/sys/kernel/mm/numa/demotion_enabled: $DEMOTION_ENABLED (1)"
    echo "/proc/sys/kernel/numa_balancing_promote_rate_limit_MBps: $NUMA_BALANCING_PROMOTE_RATE_LIMIT_MBPS"
    echo "/sys/kernel/mm/lru_gen/enabled: $MGLRU_ENABLED"
    echo "/proc/sys/vm/watermark_scale_factor: $WATERMARK_SCALE_FACTOR (200)"
    exit 1
  fi

  echo "AutoNUMA setup successful."
  echo "numad service status: $NUMAD_OUT (inactive)"
  echo "/proc/sys/vm/zone_reclaim_mode: $ZONE_RECLAIM_MODE (15)"
  echo "/proc/sys/kernel/numa_balancing: $NUMA_BALANCING (2)"
  echo "/sys/kernel/mm/numa/demotion_enabled: $DEMOTION_ENABLED (1)"
  echo "/proc/sys/kernel/numa_balancing_promote_rate_limit_MBps: $NUMA_BALANCING_PROMOTE_RATE_LIMIT_MBPS"
  echo "/sys/kernel/mm/lru_gen/enabled: $MGLRU_ENABLED ($MGLRU_VAL)"
  echo "/proc/sys/vm/watermark_scale_factor: $WATERMARK_SCALE_FACTOR (200)"
}

# disable any type of NUMA management, such as AutoNUMA and TPP
disable_numa () {
  # check Linux kernel version
  KERNEL_VER=$(uname -r)
  if [ "$KERNEL_VER" != "$NO_NUMA_KERNEL_VER" ] ; then
    echo "ERROR! Expecting kernel version $NO_NUMA_KERNEL_VER to evaluate solutions that has Linux NUMA disabled, but $KERNEL_VER detected."
    echo "The expected kernel version is defined as NO_NUMA_KERNEL_VER in ${BIGMEMBENCH_COMMON_PATH}/run_exp_common.sh"
    exit 1
  fi

  # check kernel parameters
  sudo service numad stop
  echo 0 > /proc/sys/vm/zone_reclaim_mode
  echo 0 > /proc/sys/kernel/numa_balancing
  echo 0 > /sys/kernel/mm/numa/demotion_enabled
  echo n > /sys/kernel/mm/lru_gen/enabled

  NUMAD_OUT=$(systemctl is-active numad)
  ZONE_RECLAIM_MODE=$(cat /proc/sys/vm/zone_reclaim_mode)
  NUMA_BALANCING=$(cat /proc/sys/kernel/numa_balancing)
  DEMOTION_ENABLED=$(cat /sys/kernel/mm/numa/demotion_enabled)
  MGLRU_ENABLED=$(cat /sys/kernel/mm/lru_gen/enabled)

  if [ "$ZONE_RECLAIM_MODE" != "0" ] \
  || [ "$NUMA_BALANCING" != "0" ] \
  || [ "$DEMOTION_ENABLED" != "false" ] \
  || [ "$MGLRU_ENABLED" != "0x0000" ] \
  || [ "$NUMAD_OUT" != "inactive" ] ; then
    echo "ERROR! Disable AutoNUMA kernel parameter configuration failed."
    echo "numad service status: $NUMAD_OUT (inactive)"
    echo "/proc/sys/vm/zone_reclaim_mode: $ZONE_RECLAIM_MODE (0)"
    echo "/proc/sys/kernel/numa_balancing: $NUMA_BALANCING (0)"
    echo "/sys/kernel/mm/numa/demotion_enabled: $DEMOTION_ENABLED (0)"
    echo "/sys/kernel/mm/lru_gen/enabled: $MGLRU_ENABLED (0x0000)"
    exit 1
  fi

  echo "Disable NUMA setup successful."
  echo "numad service status: $NUMAD_OUT (inactive)"
  echo "/proc/sys/vm/zone_reclaim_mode: $ZONE_RECLAIM_MODE (0)"
  echo "/proc/sys/kernel/numa_balancing: $NUMA_BALANCING (0)"
  echo "/sys/kernel/mm/numa/demotion_enabled: $DEMOTION_ENABLED (0)"
  echo "/sys/kernel/mm/lru_gen/enabled: $MGLRU_ENABLED (0x0000)"
}

# setup environment for HybridTier tiering
enable_hybridtier () {
  # check Linux kernel version
  KERNEL_VER=$(uname -r)
  if [ "$KERNEL_VER" != "$HYBRIDTIER_KERNEL_VER" ] ; then
    echo "ERROR! Expecting kernel version $NO_NUMA_KERNEL_VER to evaluate solutions that has Linux NUMA disabled, but $KERNEL_VER detected."
    echo "The expected kernel version is defined as NO_NUMA_KERNEL_VER in ${BIGMEMBENCH_COMMON_PATH}/run_exp_common.sh"
    exit 1
  fi

  # check kernel parameters
  sudo service numad stop
  echo 0 > /proc/sys/vm/zone_reclaim_mode
  echo 0 > /proc/sys/kernel/numa_balancing
  echo 0 > /sys/kernel/mm/numa/demotion_enabled
  # watermark factor of 0 is not allowed, so set to 10
  echo 10 > /proc/sys/vm/watermark_scale_factor 
  echo 0x0000 > /sys/kernel/mm/lru_gen/enabled

  NUMAD_OUT=$(systemctl is-active numad)
  ZONE_RECLAIM_MODE=$(cat /proc/sys/vm/zone_reclaim_mode)
  NUMA_BALANCING=$(cat /proc/sys/kernel/numa_balancing)
  DEMOTION_ENABLED=$(cat /sys/kernel/mm/numa/demotion_enabled)
  WATERMARK_SCALE_FACTOR=$(cat /proc/sys/vm/watermark_scale_factor)
  LRU_GEN=$(cat /sys/kernel/mm/lru_gen/enabled)

  if [ "$ZONE_RECLAIM_MODE" != "0" ] \
  || [ "$NUMA_BALANCING" != "0" ] \
  || [ "$DEMOTION_ENABLED" != "false" ] \
  || [ "$LRU_GEN" != "0x0000" ] \
  || [ "$WATERMARK_SCALE_FACTOR" != "10" ] \
  || [ "$NUMAD_OUT" != "inactive" ] ; then
    echo "ERROR! HYBRIDTIER kernel parameter configuration failed."
    echo "numad service status: $NUMAD_OUT (inactive)"
    echo "/proc/sys/vm/zone_reclaim_mode: $ZONE_RECLAIM_MODE (0)"
    echo "/proc/sys/kernel/numa_balancing: $NUMA_BALANCING (0)"
    echo "/sys/kernel/mm/numa/demotion_enabled: $DEMOTION_ENABLED (false)"
    echo "/sys/kernel/mm/lru_gen/enabled: $LRU_GEN (0x0000)"
    echo "/proc/sys/vm/watermark_scale_factor: $WATERMARK_SCALE_FACTOR (10)"
    exit 1
  fi

  echo "HYBRIDTIER setup successful."
  echo "numad service status: $NUMAD_OUT (inactive)"
  echo "/proc/sys/vm/zone_reclaim_mode: $ZONE_RECLAIM_MODE (0)"
  echo "/proc/sys/kernel/numa_balancing: $NUMA_BALANCING (0)"
  echo "/sys/kernel/mm/numa/demotion_enabled: $DEMOTION_ENABLED (false)"
  echo "/sys/kernel/mm/lru_gen/enabled: $LRU_GEN (0x0000)"
}

gen_file_name () {
  KERNEL=$1
  INPUT=$2
  SETUP=$3
  LOGNAME=$4

  DATE=$(date +"%Y%m%d_%H%M%S")
  #echo "${KERNEL}-${INPUT}-${SETUP}-${DATE}"
  #if [ "$LOGNAME" != "" ]; then
  if [ -z "$LOGNAME" ]; then
    echo "${KERNEL}-${INPUT}-${SETUP}-${DATE}"
  else 
    echo "${KERNEL}-${INPUT}-${SETUP}-${DATE}-${LOGNAME}"
  fi
}
  
get_cmd_prefix () {
  CONFIG=$1

  TIME_PREFIX="/usr/bin/time -f 'execution time %e (s)'"

  if [[ "$CONFIG" == "ALL_LOCAL" ]]; then
    # All local config: place both data and compute on node 1
    RET_CMD="${TIME_PREFIX} /usr/bin/numactl --membind=0 --cpunodebind=0"
  elif [[ "$CONFIG" == "EDGES_ON_REMOTE" ]]; then
    # place edges array on node 1, rest on node 0
    RET_CMD="${TIME_PREFIX} /usr/bin/numactl --membind=0 --cpunodebind=0"
  elif [[ "$CONFIG" == "TPP" ]]; then
    # only use node 0 CPUs and let TPP decide how memory is placed
    RET_CMD="${TIME_PREFIX} /usr/bin/numactl --cpunodebind=0"
  elif [[ "$CONFIG" == "AUTONUMA" ]]; then
    RET_CMD="${TIME_PREFIX} /usr/bin/numactl --cpunodebind=0"
  elif [[ "$CONFIG" == "HYBRIDTIER" ]]; then
    RET_CMD="${TIME_PREFIX} /usr/bin/numactl --cpunodebind=0"
  elif [[ "$CONFIG" == "ARC" ]]; then
    # since ARC assumes cache is initially empty, start by allocating every on slow tier
    RET_CMD="${TIME_PREFIX} /usr/bin/numactl --membind=1 --cpunodebind=0"
  elif [[ "$CONFIG" == "TWOQ" ]]; then
    # since TWOQ assumes cache is initially empty, start by allocating every on slow tier
    RET_CMD="${TIME_PREFIX} /usr/bin/numactl --membind=1 --cpunodebind=0"
  elif [[ "$CONFIG" == "MULTICLOCK" ]]; then
    RET_CMD="${TIME_PREFIX} /usr/bin/numactl --cpunodebind=0"
  elif [[ "$CONFIG" == "NO_TIERING" ]]; then
    RET_CMD="${TIME_PREFIX} /usr/bin/numactl --cpunodebind=0"
  elif [[ "$CONFIG" == "HEMEM" ]]; then
    RET_CMD="${TIME_PREFIX} /usr/bin/numactl --membind=1 --cpunodebind=0"
  else
    echo "Error! Undefined configuration $CONFIG"
    exit 1
  fi
  echo $RET_CMD
}

write_frontmatter () {
  OUTFILE_PATH=$1
  
  echo "Start" > $OUTFILE_PATH

  echo "=======================" >> $OUTFILE_PATH
  echo "NUMA hardware configs" >> $OUTFILE_PATH
  NUMACTL_OUT=$(numactl -H)
  echo "$NUMACTL_OUT" >> $OUTFILE_PATH

  echo "=======================" >> $OUTFILE_PATH
  echo "Migration counters before" >> $OUTFILE_PATH
  MIGRATION_STAT=$(grep -E "pgdemote|pgpromote|pgmigrate|numa" /proc/vmstat)
  echo "$MIGRATION_STAT" >> $OUTFILE_PATH

  echo "=======================" >> $OUTFILE_PATH
  echo "NUMA statistics before" >> $OUTFILE_PATH
  NUMA_STAT=$(numastat)
  echo "$NUMA_STAT" >> $OUTFILE_PATH

}

start_perf_stat () {
  PERF_STAT_INTERVAL=$1
  OUTFILE_PATH=$2

  if [ -z "$OUTFILE_PATH" ]; then
    echo "Error when using run_exp_common.h: OUTFILE_PATH not given"
  fi

  #echo "${PERF_EXE} stat -e mem_load_l3_miss_retired.local_dram -e mem_load_l3_miss_retired.remote_dram -I ${PERF_STAT_INTERVAL} -x , --output ${OUTFILE_PATH}_memhit &"
  ${PERF_EXE} stat -e mem_load_l3_miss_retired.local_dram -e mem_load_l3_miss_retired.remote_dram -I ${PERF_STAT_INTERVAL} -x , --output ${OUTFILE_PATH}_memhit &
  PERF_STAT_PID=$!
  echo "perf stat pid is $PERF_STAT_PID"
}

kill_perf_stat () {
  echo "Stopped perf stat"
  kill $PERF_STAT_PID
  kill $(pidof perf)
}

write_backmatter () {
  OUTFILE_PATH=$1

  echo "kernel complete."

  echo "=======================" >> $OUTFILE_PATH
  echo "Migration counters after" >> $OUTFILE_PATH
  MIGRATION_STAT=$(grep -E "pgdemote|pgpromote|pgmigrate|numa" /proc/vmstat)
  echo "$MIGRATION_STAT" >> $OUTFILE_PATH

  echo "=======================" >> $OUTFILE_PATH
  echo "NUMA statistics after" >> $OUTFILE_PATH
  NUMA_STAT=$(numastat)
  echo "$NUMA_STAT" >> $OUTFILE_PATH

}

setup_vtune () {
  # Not loading the drivers for now. Was not able to build the vtune drivers for 6.1-rc6
  #pushd /opt/intel/oneapi/vtune/latest/sepdk/src
  #./insmod-sep -r -g vtune
  #popd

  echo 0 > /proc/sys/kernel/perf_event_paranoid
  echo 0 > /proc/sys/kernel/kptr_restrict
  echo 0 > /proc/sys/kernel/yama/ptrace_scope

  PERF_EVENT_PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid)
  KPTR_RESTRICT=$(cat /proc/sys/kernel/kptr_restrict)
  PTRACE_SCOPE=$(cat /proc/sys/kernel/yama/ptrace_scope)

  if [ "$PERF_EVENT_PARANOID" != "0" ] \
  || [ "$KPTR_RESTRICT" != "0" ] \
  || [ "$PTRACE_SCOPE" != "0" ] ; then
    echo "ERROR! Setup Vtune kernel parameter configuration failed."
    echo "/proc/sys/kernel/perf_event_paranoid: $PERF_EVENT_PARANOID (0)"
    echo "/proc/sys/kernel/kptr_restrict: $KPTR_RESTRICT (0)" 
    echo "/proc/sys/kernel/yama/ptrace_scope: $PTRACE_SCOPE (0)"
    exit 1
  fi

  echo "Vtune setup successful."
}


huge_page_off () {
  echo "Turning huge page OFF"
  echo "never" | tee /sys/kernel/mm/transparent_hugepage/enabled
  echo "never" | tee /sys/kernel/mm/transparent_hugepage/defrag
  echo 0 | tee /sys/kernel/mm/transparent_hugepage/khugepaged/defrag
  echo 0 | tee /proc/sys/vm/compaction_proactiveness
  #cat /sys/kernel/mm/transparent_hugepage/enabled
  #cat /sys/kernel/mm/transparent_hugepage/defrag
  #cat /sys/kernel/mm/transparent_hugepage/khugepaged/defrag
  #cat /proc/sys/vm/compaction_proactiveness
}

huge_page_on () {
  echo "Turning huge page ON"
  echo "always" | tee /sys/kernel/mm/transparent_hugepage/enabled
  echo "always" | tee /sys/kernel/mm/transparent_hugepage/defrag
  echo 1 | tee /sys/kernel/mm/transparent_hugepage/khugepaged/defrag
  echo 20 | tee /proc/sys/vm/compaction_proactiveness
  #echo "never" | tee /sys/kernel/mm/transparent_hugepage/defrag
  #echo 0 | tee /sys/kernel/mm/transparent_hugepage/khugepaged/defrag
  #echo 0 | tee /proc/sys/vm/compaction_proactiveness

  #echo "turning both defrags off, compaction proactiveness off"
  #cat /sys/kernel/mm/transparent_hugepage/enabled
  #cat /sys/kernel/mm/transparent_hugepage/defrag
  #cat /sys/kernel/mm/transparent_hugepage/khugepaged/defrag
  #cat /proc/sys/vm/compaction_proactiveness
}


[[ $EUID -ne 0 ]] && echo "This script must be run using sudo or as root." && exit 1
# Turn off swap to SSD
swapoff /swap.img

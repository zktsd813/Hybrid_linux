#!/usr/bin/env python3

import argparse
import importlib.util
import json
import re
import shlex
import subprocess
import sys
import time
import os
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
REFERENCE_SCRIPT = Path("/Serverless/Migration-friendly/scripts/bench_V2/run_host_mode2_coarse_sweep.py")
HOOK_SOURCE = SCRIPT_DIR / "hook" / "hook.cpp"

DEFAULT_CPU_NODE = 0
DEFAULT_LOCAL_NODE = 0
DEFAULT_REMOTE_NODE = 2
DEFAULT_MONITOR_NODE = 1
DEFAULT_KSWAPD_DEMOTION_MODE = 0x4
DEFAULT_DEMOTE_SCALE_FACTOR = 400
DEFAULT_CAP_GB_LIST = "8,16,32"
DEFAULT_BW_INTERVAL = 1.0
DEFAULT_OUT_ROOT = SCRIPT_DIR / "host_hybridtier_mode4_sweeps"
DEFAULT_CGROUP_PREFIX = "benchv2_hybridtier_mode4"
DEFAULT_PCM_MEMORY = "/usr/local/sbin/pcm-memory"
DEFAULT_PCM_IIO = "/usr/local/sbin/pcm-iio"
DEFAULT_PAGE_TYPE = "regular"
DEFAULT_MEM_POLICY = "localalloc"
DEFAULT_MEMORY_MAX = "max"
DEFAULT_LOW_WMARK_PCT = 90
DEFAULT_HIGH_WMARK_PCT = 95
DEFAULT_WORKLOAD_SPEC = "all"

HYBRID_PAGES_MIGRATED_RE = re.compile(r"pages migrated:\s*([0-9,]+)")
HYBRID_PROMO_BATCH_RE = re.compile(r"migrating one batch of pages\s+([0-9]+)")
HYBRID_PAGES_DEMOTED_RE = re.compile(r"pages_demoted\s+([0-9]+)")
HYBRID_DEMOTION_RATE_RE = re.compile(r"Demotion rate:\s*([0-9.]+)")
HYBRID_FAST_AVAIL_RE = re.compile(r"fast tier available bytes\s+([0-9]+)")


def load_reference_module():
    if not REFERENCE_SCRIPT.exists():
        raise RuntimeError(f"missing reference script: {REFERENCE_SCRIPT}")
    spec = importlib.util.spec_from_file_location("benchv2_host_mode2", REFERENCE_SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load module spec from {REFERENCE_SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


REF = load_reference_module()

WORKLOAD_COMMANDS = REF.WORKLOAD_COMMANDS
VMSTAT_KEYS = REF.VMSTAT_KEYS
MEMSTAT_KEYS = REF.MEMSTAT_KEYS
RECLAIMD_KEYS = REF.RECLAIMD_KEYS
MIGRATE_KEYS = REF.MIGRATE_KEYS


def require_root():
    if os.geteuid() == 0:
        return
    os.execvp("sudo", ["sudo", "-E", sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]])


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Host-side HybridTier coarse sweep runner. "
            "Mirrors bench_V2 host_mode2 harness structure, "
            "but runs workloads under HybridTier with memory.kswapd_demotion_enabled=4."
        )
    )
    parser.add_argument(
        "--workloads",
        default=DEFAULT_WORKLOAD_SPEC,
        help=(
            f"Comma-separated workload names, or 'all'. Defaults to '{DEFAULT_WORKLOAD_SPEC}'. "
            f"Supported workloads: {', '.join(WORKLOAD_COMMANDS.keys())}."
        ),
    )
    parser.add_argument(
        "--local-cap-gb-list",
        default=DEFAULT_CAP_GB_LIST,
        help="Comma-separated memory.node_capacity values in GiB for the fast tier.",
    )
    parser.add_argument("--cpu-node", type=int, default=DEFAULT_CPU_NODE)
    parser.add_argument("--local-node", type=int, default=DEFAULT_LOCAL_NODE)
    parser.add_argument("--remote-node", type=int, default=DEFAULT_REMOTE_NODE)
    parser.add_argument("--monitor-node", type=int, default=DEFAULT_MONITOR_NODE)
    parser.add_argument(
        "--kswapd-demotion-mode",
        type=REF.parse_int_auto,
        default=DEFAULT_KSWAPD_DEMOTION_MODE,
        help="memcg demotion mode. This runner is fixed to 0x4.",
    )
    parser.add_argument("--demote-scale-factor", type=int, default=DEFAULT_DEMOTE_SCALE_FACTOR)
    parser.add_argument("--bandwidth-interval-sec", type=float, default=DEFAULT_BW_INTERVAL)
    parser.add_argument("--pcm-memory-bin", default=DEFAULT_PCM_MEMORY)
    parser.add_argument("--pcm-iio-bin", default=DEFAULT_PCM_IIO)
    parser.add_argument(
        "--disable-hyperthreading",
        dest="disable_hyperthreading",
        action="store_true",
        default=True,
        help="Disable SMT/Hyper-Threading before running workloads. Enabled by default.",
    )
    parser.add_argument(
        "--keep-hyperthreading",
        dest="disable_hyperthreading",
        action="store_false",
        help="Leave SMT/Hyper-Threading unchanged.",
    )
    parser.add_argument("--out-root", default=str(DEFAULT_OUT_ROOT))
    parser.add_argument("--run-id", default=time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
    parser.add_argument("--cgroup-prefix", default=DEFAULT_CGROUP_PREFIX)
    parser.add_argument("--limit-configs", type=int, default=0, help="If set, run only the first N configs.")
    parser.add_argument("--skip-prepare", action="store_true", help="Skip host-level demotion/CXL setup.")
    parser.add_argument("--page-type", choices=("regular", "huge"), default=DEFAULT_PAGE_TYPE)
    parser.add_argument(
        "--mem-policy",
        choices=("default", "localalloc", "bind_slow"),
        default=DEFAULT_MEM_POLICY,
        help="numactl memory policy used for workload launch. Defaults to localalloc.",
    )
    parser.add_argument(
        "--memory-max",
        default=DEFAULT_MEMORY_MAX,
        help="Value written to cgroup memory.max. Defaults to max.",
    )
    parser.add_argument("--low-watermark-pct", type=int, default=DEFAULT_LOW_WMARK_PCT)
    parser.add_argument("--high-watermark-pct", type=int, default=DEFAULT_HIGH_WMARK_PCT)
    parser.add_argument(
        "--hybridtier-extra-compile-args",
        default="",
        help="Extra compiler flags appended when building hook.so.",
    )
    return parser.parse_args()


def cgroup_knob_path(cg_path, name):
    for candidate in (cg_path / name, cg_path / f"memory.{name}"):
        if candidate.exists():
            return candidate
    return None


def require_cgroup_knob(cg_path, name):
    path = cgroup_knob_path(cg_path, name)
    if path is None:
        raise FileNotFoundError(f"cgroup knob not found: {name} under {cg_path}")
    return path


def write_cgroup_knob(cg_path, name, value):
    REF.write_sysfs(require_cgroup_knob(cg_path, name), value)


def write_cgroup_knob_if_present(cg_path, name, value):
    path = cgroup_knob_path(cg_path, name)
    if path is None:
        return False
    REF.write_sysfs(path, value)
    return True


def read_text(path):
    return Path(path).read_text(encoding="utf-8").strip()


def read_text_if_exists(path):
    target = Path(path)
    if not target.exists():
        return ""
    return read_text(target)


def save_text(path, text):
    Path(path).write_text(text, encoding="utf-8")


def save_json(path, data):
    Path(path).write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")


def save_text_map(path, data):
    with open(path, "w", encoding="utf-8") as f:
        for key in sorted(data):
            f.write(f"{key} {data[key]}\n")


def parse_stat_file(path):
    data = {}
    if path is None or not path.exists():
        return data
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            parts = raw.strip().split()
            if len(parts) != 2:
                continue
            key, value = parts
            try:
                data[key] = int(value)
            except ValueError:
                continue
    return data


def parse_flat_kv_file(path):
    data = {}
    if path is None or not path.exists():
        return data
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            parts = raw.strip().split(None, 1)
            if len(parts) != 2:
                continue
            key, value = parts
            try:
                data[key] = int(value)
            except ValueError:
                continue
    return data


def snapshot_cgroup_stats(cg_path):
    stat = parse_stat_file(cgroup_knob_path(cg_path, "stat"))
    reclaimd = parse_flat_kv_file(cgroup_knob_path(cg_path, "reclaimd_state"))
    migrate = parse_flat_kv_file(cgroup_knob_path(cg_path, "numa_migrate_state"))

    snap = {}
    for key in MEMSTAT_KEYS:
        snap[f"MEMSTAT.{key}"] = stat.get(key, 0)
    for key in RECLAIMD_KEYS:
        snap[f"RECLAIMD.{key}"] = reclaimd.get(key, 0)
    for key in MIGRATE_KEYS:
        snap[f"MIGRATE.{key}"] = migrate.get(key, 0)
    return snap


def copy_cgroup_file_if_present(cg_path, name, dst_path):
    path = cgroup_knob_path(cg_path, name)
    if path is None:
        return False
    save_text(dst_path, path.read_text(encoding="utf-8"))
    return True


def build_configs(cap_gb_list):
    return [{"local_cap_gb": cap_gb} for cap_gb in cap_gb_list]


def first_token_basename(command):
    argv = shlex.split(command)
    if not argv:
        raise RuntimeError(f"empty command: {command!r}")
    return Path(argv[0]).name


def preflight_required_knobs(cgroup_prefix):
    REF.enable_cgroup_controllers()
    probe = REF.CGROUP_ROOT / f"{cgroup_prefix}_probe"
    REF.reset_cgroup_dir(probe)
    probe.mkdir(parents=True, exist_ok=True)
    try:
        missing = []
        for knob in ["node_capacity", "kswapd_demotion_enabled", "stat", "numa_stat"]:
            if cgroup_knob_path(probe, knob) is None:
                missing.append(knob)
        if missing:
            raise RuntimeError("host kernel is missing required cgroup knobs: " + ", ".join(missing))
        try:
            write_cgroup_knob(probe, "kswapd_demotion_enabled", str(DEFAULT_KSWAPD_DEMOTION_MODE))
        except subprocess.CalledProcessError as exc:
            raise RuntimeError(
                "host kernel exposes memory.kswapd_demotion_enabled but does not accept mode=4"
            ) from exc
    finally:
        REF.reset_cgroup_dir(probe)


def configure_host_for_hybridtier(local_node, remote_node, demote_scale_factor):
    REF.write_sysfs_if_exists("/proc/sys/vm/demote_scale_factor", demote_scale_factor)
    REF.write_sysfs("/sys/kernel/mm/numa/demotion_enabled", "1")
    REF.write_sysfs("/sys/kernel/mm/numa/demotion_target", f"{local_node} {remote_node}")
    REF.write_sysfs("/proc/sys/kernel/numa_balancing", "0")
    REF.write_sysfs_if_exists("/proc/sys/vm/zone_reclaim_mode", "0")


def setup_cgroup(args, cg_name, cap_pages):
    REF.enable_cgroup_controllers()
    cg_path = REF.CGROUP_ROOT / cg_name
    REF.reset_cgroup_dir(cg_path)
    cg_path.mkdir(parents=True, exist_ok=True)

    REF.write_sysfs(cg_path / "cpuset.cpus", REF.node_cpulist(args.cpu_node))
    REF.write_sysfs(cg_path / "cpuset.mems", f"{args.local_node},{args.remote_node}")
    REF.write_sysfs(cg_path / "memory.max", args.memory_max)
    if (cg_path / "memory.high").exists():
        REF.write_sysfs(cg_path / "memory.high", "max")
    if (cg_path / "memory.low").exists():
        REF.write_sysfs(cg_path / "memory.low", "0")

    write_cgroup_knob(cg_path, "node_capacity", f"{args.local_node} {cap_pages}")

    low_pages = cap_pages * args.low_watermark_pct // 100
    high_pages = cap_pages * args.high_watermark_pct // 100
    if low_pages > high_pages:
        raise RuntimeError(
            f"invalid watermarks: low={args.low_watermark_pct}% high={args.high_watermark_pct}%"
        )
    if high_pages > cap_pages:
        raise RuntimeError(f"high watermark exceeds capacity: {high_pages} > {cap_pages}")

    write_cgroup_knob_if_present(cg_path, "node_low_wmark", f"{args.local_node} {low_pages}")
    write_cgroup_knob_if_present(cg_path, "node_high_wmark", f"{args.local_node} {high_pages}")
    write_cgroup_knob(cg_path, "kswapd_demotion_enabled", str(args.kswapd_demotion_mode))
    write_cgroup_knob_if_present(cg_path, "node_force_lru_evict", f"{args.local_node} 1")
    return cg_path


def effective_cpu_count(cg_path, cpu_node):
    for candidate in (cg_path / "cpuset.cpus.effective", cg_path / "cpuset.cpus"):
        if candidate.exists():
            cpulist = candidate.read_text(encoding="utf-8").strip()
            if cpulist:
                return len(REF.expand_cpulist(cpulist))
    return len(REF.expand_cpulist(REF.node_cpulist(cpu_node)))


def build_hybridtier_hook(outdir, workload, command, cap_gb, page_type, extra_compile_args):
    if not HOOK_SOURCE.exists():
        raise RuntimeError(f"missing HybridTier hook source: {HOOK_SOURCE}")

    compiler = REF.which_required_binary("g++")
    hook_so = outdir / "hook.so"
    build_log = outdir / "hook.build.txt"
    target_exe = first_token_basename(command)
    page_macro = "HYBRIDTIER_HUGE" if page_type == "huge" else "HYBRIDTIER_REGULAR"

    cmd = [
        compiler,
        "-shared",
        "-fPIC",
        "-g",
        str(HOOK_SOURCE),
        "-o",
        str(hook_so),
        "-O3",
        "-ldl",
        "-lpthread",
        "-lnuma",
        f"-DFAST_MEMORY_SIZE_GB={cap_gb}",
        f'-DTARGET_EXE_NAME="{target_exe}"',
        f"-D{page_macro}",
    ]
    if extra_compile_args:
        cmd.extend(shlex.split(extra_compile_args))

    result = subprocess.run(cmd, capture_output=True, text=True)
    build_text = "\n".join(
        [
            "command:",
            " ".join(shlex.quote(part) for part in cmd),
            "",
            "stdout:",
            result.stdout,
            "",
            "stderr:",
            result.stderr,
        ]
    )
    save_text(build_log, build_text)
    if result.returncode != 0:
        raise RuntimeError(f"failed to build hook.so for {workload}; see {build_log}")
    return hook_so, target_exe


def build_launch_command(command, numactl_bin, cpu_node, remote_node, mem_policy):
    parts = [shlex.quote(numactl_bin), f"--cpunodebind={cpu_node}"]
    if mem_policy == "localalloc":
        parts.append("--localalloc")
    elif mem_policy == "bind_slow":
        parts.append(f"--membind={remote_node}")
    elif mem_policy != "default":
        raise RuntimeError(f"unsupported mem_policy={mem_policy}")
    parts.append(command)
    return " ".join(parts)


def run_hybridtier_workload(cg_path, command, outdir, hook_so, numactl_bin, cpu_node, remote_node, mem_policy):
    stdout_path = outdir / "workload.stdout.txt"
    runner_path = outdir / "workload.runner.txt"
    launch_cmd = build_launch_command(command, numactl_bin, cpu_node, remote_node, mem_policy)
    omp_threads = effective_cpu_count(cg_path, cpu_node)
    shell_cmd = (
        f"echo $$ > {shlex.quote(str(cg_path / 'cgroup.procs'))}; "
        f"export LD_PRELOAD={shlex.quote(str(hook_so))}; "
        f"export OMP_NUM_THREADS={omp_threads}; "
        f"export OMP_PROC_BIND=true; "
        f"export OMP_PLACES=cores; "
        f"exec /usr/bin/time -f {shlex.quote('execution time %e (s)')} {launch_cmd}"
    )

    save_text(runner_path, shell_cmd + "\n")
    proc = subprocess.Popen(
        ["bash", "-lc", shell_cmd],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    lines = []
    with open(stdout_path, "w", encoding="utf-8") as out_f:
        assert proc.stdout is not None
        for line in proc.stdout:
            sys.stdout.write(line)
            out_f.write(line)
            out_f.flush()
            lines.append(line)

    ret = proc.wait()
    return ret, "".join(lines)


def parse_hybridtier_metrics(text):
    metrics = {}

    pages_migrated = [
        int(match.group(1).replace(",", "")) for match in HYBRID_PAGES_MIGRATED_RE.finditer(text)
    ]
    promo_batches = [int(match.group(1)) for match in HYBRID_PROMO_BATCH_RE.finditer(text)]
    demoted_batches = [int(match.group(1)) for match in HYBRID_PAGES_DEMOTED_RE.finditer(text)]
    demotion_rates = [float(match.group(1)) for match in HYBRID_DEMOTION_RATE_RE.finditer(text)]
    fast_available = [int(match.group(1)) for match in HYBRID_FAST_AVAIL_RE.finditer(text)]

    metrics["hybridtier.promotion_events"] = len(promo_batches)
    metrics["hybridtier.promotion_requested_pages"] = sum(promo_batches)
    metrics["hybridtier.demotion_events"] = len(demoted_batches)
    metrics["hybridtier.demotion_pages"] = sum(demoted_batches)

    if pages_migrated:
        metrics["hybridtier.pages_migrated_total"] = pages_migrated[-1]
        metrics["hybridtier.pages_migrated_peak"] = max(pages_migrated)
    if demotion_rates:
        metrics["hybridtier.demotion_rate_peak_bytes_per_s"] = max(demotion_rates)
        metrics["hybridtier.demotion_rate_last_bytes_per_s"] = demotion_rates[-1]
    if fast_available:
        metrics["hybridtier.fast_tier_available_last_bytes"] = fast_available[-1]
        metrics["hybridtier.fast_tier_available_min_bytes"] = min(fast_available)

    return metrics


def main():
    require_root()
    args = parse_args()

    if args.kswapd_demotion_mode != DEFAULT_KSWAPD_DEMOTION_MODE:
        raise SystemExit("--kswapd-demotion-mode must stay 0x4 for this HybridTier runner")
    if not (0 < args.low_watermark_pct <= args.high_watermark_pct <= 100):
        raise SystemExit("--low-watermark-pct and --high-watermark-pct must satisfy 0 < low <= high <= 100")

    workloads = REF.parse_workloads(args.workloads)
    cap_gb_list = REF.parse_int_list(args.local_cap_gb_list)
    configs = build_configs(cap_gb_list)
    if args.limit_configs:
        configs = configs[: args.limit_configs]

    monitor_cpu = REF.first_cpu_of_node(args.monitor_node)
    pcm_memory_bin = REF.which_required_binary(args.pcm_memory_bin)
    pcm_iio_bin = REF.which_required_binary(args.pcm_iio_bin)
    numactl_bin = REF.which_required_binary("numactl")

    out_root = Path(args.out_root) / args.run_id
    out_root.mkdir(parents=True, exist_ok=True)
    smt_before = read_text_if_exists("/sys/devices/system/cpu/smt/control")
    smt_after = REF.configure_hyperthreading(args.disable_hyperthreading)
    save_text(out_root / Path(__file__).name, Path(__file__).read_text(encoding="utf-8"))

    host_knobs_before = {
        "kernel.numa_balancing": read_text_if_exists("/proc/sys/kernel/numa_balancing"),
        "vm.zone_reclaim_mode": read_text_if_exists("/proc/sys/vm/zone_reclaim_mode"),
        "numa.demotion_enabled": read_text_if_exists("/sys/kernel/mm/numa/demotion_enabled"),
        "numa.demotion_target": read_text_if_exists("/sys/kernel/mm/numa/demotion_target"),
        "vm.demote_scale_factor": read_text_if_exists("/proc/sys/vm/demote_scale_factor"),
    }

    run_meta = {
        "reference_script": str(REFERENCE_SCRIPT),
        "workloads": workloads,
        "cpu_node": args.cpu_node,
        "local_node": args.local_node,
        "remote_node": args.remote_node,
        "monitor_node": args.monitor_node,
        "monitor_cpu": monitor_cpu,
        "kswapd_demotion_mode": args.kswapd_demotion_mode,
        "cap_gb_list": cap_gb_list,
        "pcm_memory_bin": pcm_memory_bin,
        "pcm_iio_bin": pcm_iio_bin,
        "numactl_bin": numactl_bin,
        "page_type": args.page_type,
        "mem_policy": args.mem_policy,
        "memory_max": args.memory_max,
        "low_watermark_pct": args.low_watermark_pct,
        "high_watermark_pct": args.high_watermark_pct,
        "hybridtier_extra_compile_args": args.hybridtier_extra_compile_args,
        "disable_hyperthreading": args.disable_hyperthreading,
        "smt_control_before": smt_before,
        "smt_control_after": smt_after,
        "host_knobs_before": host_knobs_before,
    }
    save_json(out_root / "run_meta.json", run_meta)
    REF.capture_pcm_iio_topology(pcm_iio_bin, out_root / "pcm-iio-topology.txt")

    preflight_required_knobs(args.cgroup_prefix)

    if not args.skip_prepare:
        REF.ensure_remote_node_online(args.remote_node)
        configure_host_for_hybridtier(args.local_node, args.remote_node, args.demote_scale_factor)

    host_knobs_after_prepare = {
        "kernel.numa_balancing": read_text_if_exists("/proc/sys/kernel/numa_balancing"),
        "vm.zone_reclaim_mode": read_text_if_exists("/proc/sys/vm/zone_reclaim_mode"),
        "numa.demotion_enabled": read_text_if_exists("/sys/kernel/mm/numa/demotion_enabled"),
        "numa.demotion_target": read_text_if_exists("/sys/kernel/mm/numa/demotion_target"),
        "vm.demote_scale_factor": read_text_if_exists("/proc/sys/vm/demote_scale_factor"),
    }
    save_json(out_root / "host_knobs.after_prepare.json", host_knobs_after_prepare)

    summary_rows = []
    for workload in workloads:
        command = WORKLOAD_COMMANDS[workload]
        for cfg in configs:
            cap_gb = cfg["local_cap_gb"]
            cfg_name = f"cap{cap_gb}g"
            outdir = out_root / workload / cfg_name
            outdir.mkdir(parents=True, exist_ok=True)

            hook_so, target_exe = build_hybridtier_hook(
                outdir,
                workload,
                command,
                cap_gb,
                args.page_type,
                args.hybridtier_extra_compile_args,
            )

            cg_name = f"{args.cgroup_prefix}_{workload}_{cfg_name}".replace(".", "_")
            cg_path = setup_cgroup(args, cg_name, REF.capacity_pages_from_gb(cap_gb))

            vm_before = REF.snapshot_vmstat()
            cg_before = snapshot_cgroup_stats(cg_path)
            node_local_before = REF.get_node_meminfo_kb(args.local_node)
            node_remote_before = REF.get_node_meminfo_kb(args.remote_node)

            pcm_handles = REF.start_pcm_monitors(
                outdir,
                monitor_cpu,
                args.bandwidth_interval_sec,
                pcm_memory_bin,
                pcm_iio_bin,
            )

            start = time.monotonic()
            ret = 0
            output = ""
            try:
                print(f"[run] {workload} {cfg_name}")
                ret, output = run_hybridtier_workload(
                    cg_path,
                    command,
                    outdir,
                    hook_so,
                    numactl_bin,
                    args.cpu_node,
                    args.remote_node,
                    args.mem_policy,
                )
            finally:
                pcm_status = REF.stop_pcm_monitors(pcm_handles)

            elapsed = time.monotonic() - start
            vm_after = REF.snapshot_vmstat()
            cg_after = snapshot_cgroup_stats(cg_path)
            node_local_after = REF.get_node_meminfo_kb(args.local_node)
            node_remote_after = REF.get_node_meminfo_kb(args.remote_node)

            vm_diff = REF.diff_numeric(vm_before, vm_after, VMSTAT_KEYS)
            cg_diff = REF.diff_numeric(cg_before, cg_after)
            save_text_map(outdir / "vmstat.diff", vm_diff)
            save_text_map(outdir / "cgroup.diff", cg_diff)
            save_json(outdir / f"node{args.local_node}.meminfo.before.json", node_local_before)
            save_json(outdir / f"node{args.local_node}.meminfo.after.json", node_local_after)
            save_json(outdir / f"node{args.remote_node}.meminfo.before.json", node_remote_before)
            save_json(outdir / f"node{args.remote_node}.meminfo.after.json", node_remote_after)

            copy_cgroup_file_if_present(cg_path, "stat", outdir / "cgroup.stat.after.txt")
            copy_cgroup_file_if_present(cg_path, "numa_stat", outdir / "cgroup.numa_stat.after.txt")
            copy_cgroup_file_if_present(cg_path, "reclaimd_state", outdir / "cgroup.reclaimd_state.after.txt")
            copy_cgroup_file_if_present(cg_path, "numa_migrate_state", outdir / "cgroup.numa_migrate_state.after.txt")
            copy_cgroup_file_if_present(cg_path, "node_capacity", outdir / "cgroup.node_capacity.after.txt")
            copy_cgroup_file_if_present(cg_path, "node_low_wmark", outdir / "cgroup.node_low_wmark.after.txt")
            copy_cgroup_file_if_present(cg_path, "node_high_wmark", outdir / "cgroup.node_high_wmark.after.txt")
            copy_cgroup_file_if_present(
                cg_path, "kswapd_demotion_enabled", outdir / "cgroup.kswapd_demotion_enabled.after.txt"
            )

            runtime_metrics = REF.parse_runtime_metrics(output)
            hybrid_metrics = parse_hybridtier_metrics(output)
            bw_summary = {}
            bw_summary.update(REF.summarize_pcm_memory(outdir / "pcm-memory.csv"))
            bw_summary.update(REF.summarize_pcm_iio(outdir / "pcm-iio.csv"))
            bw_summary.update({f"{name}_returncode": code for name, code in pcm_status.items()})

            row = {
                "workload": workload,
                "config": cfg_name,
                "local_cap_gb": cap_gb,
                "returncode": ret,
                "elapsed_s": round(elapsed, 3),
                "monitor_cpu": monitor_cpu,
                "page_type": args.page_type,
                "mem_policy": args.mem_policy,
                "target_exe": target_exe,
                "kswapd_demotion_mode": args.kswapd_demotion_mode,
            }
            row.update(runtime_metrics)
            row.update(hybrid_metrics)
            row.update({f"vmstat.{k}": v for k, v in vm_diff.items()})
            row.update(cg_diff)
            row.update(bw_summary)
            summary_rows.append(row)
            save_json(outdir / "summary.json", row)

            REF.reset_cgroup_dir(cg_path)

            if ret != 0:
                raise RuntimeError(f"{workload} failed for {cfg_name} with exit code {ret}")

    REF.save_summary_csv(out_root / "summary.csv", summary_rows)
    print(f"[done] artifacts={out_root}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
import argparse, json, pathlib, statistics
parser = argparse.ArgumentParser()
parser.add_argument("--baseline", nargs="+", required=True); parser.add_argument("--joint", nargs="+", required=True); parser.add_argument("--recovery", nargs="+", required=True)
for name in ("a-preload", "peer", "summary"): parser.add_argument("--" + name, required=True)
parser.add_argument("--workers", type=int, required=True); parser.add_argument("--quota-cores", type=float, required=True)
parser.add_argument("--degradation-max", type=float, required=True); parser.add_argument("--recovery-min", type=float, required=True); parser.add_argument("--baseline-cv-max", type=float, required=True)
parser.add_argument("--memory-headroom", type=int, required=True); parser.add_argument("--pid-headroom", type=int, required=True); parser.add_argument("--io-max", type=int, required=True)
args = parser.parse_args(); load = lambda paths: [json.loads(pathlib.Path(path).read_text()) for path in paths]
baseline, joint, recovery = load(args.baseline), load(args.joint), load(args.recovery); preload = json.loads(pathlib.Path(args.a_preload).read_text()); peer = pathlib.Path(args.peer).read_text(errors="replace").strip()
counts = lambda rows: [row.get("report", {}).get("processed_units", 0) for row in rows]
base_counts, joint_counts, recovery_counts = counts(baseline), counts(joint), counts(recovery)
base_median, joint_median, recovery_median = map(statistics.median, (base_counts, joint_counts, recovery_counts)); base_mean = statistics.mean(base_counts)
base_cv = statistics.pstdev(base_counts) / base_mean if base_mean else 999.0; degradation = joint_median / base_median if base_median else 999.0; recovery_ratio = recovery_median / base_median if base_median else 0.0
rate = lambda row, field: row.get(field, 0) / row["elapsed_seconds"]
base_throttle = statistics.median(rate(row, "throttled_delta_usec") for row in baseline); joint_throttle = statistics.median(rate(row, "throttled_delta_usec") for row in joint); recovery_throttle = statistics.median(rate(row, "throttled_delta_usec") for row in recovery)
def quota_ok(row):
    quota, period = row["cpu_max"].split(); return quota != "max" and abs(int(quota) / int(period) - args.quota_cores) <= 0.20
all_rows = baseline + joint + recovery
memory_ok = all(row["memory_oom_delta"] == 0 and row["memory_oom_kill_delta"] == 0 and (row["memory_max"] is None or row["memory_max"] - row["memory_current_max"] >= args.memory_headroom) for row in all_rows)
pids_ok = all(row["pids_max"] is None or row["pids_max"] - row["pids_current_max"] >= args.pid_headroom for row in all_rows)
io_ok = all(row["io_bytes_delta"] <= args.io_max for row in all_rows); input_ok = all(row["input_sha256_before"] == row["input_sha256_after"] for row in all_rows)
fanout_ok = all(row["b_processes_max"] >= args.workers + 1 and row["all_b_processes_in_root_cgroup"] is True and row["b_cpu_ticks_delta"] > 0 for row in all_rows)
a_cycle_delta = sum(row["a_after"]["compile_cycles"] - row["a_before"]["compile_cycles"] for row in joint); a_block_delta = sum(row["a_after"]["cache_blocks"] - row["a_before"]["cache_blocks"] for row in joint); a_tick_delta = sum(row["a_after"]["ticks"] - row["a_before"]["ticks"] for row in joint)
checks = {
    "trial_counts": len(baseline) == 3 and len(joint) == 3 and len(recovery) == 2,
    "b_alone_ok": all(row["returncode"] == 0 and row.get("report", {}).get("processed_units", 0) > 0 for row in baseline) and base_cv <= args.baseline_cv_max,
    "throughput_degradation": degradation <= args.degradation_max, "throughput_recovery": recovery_ratio >= args.recovery_min,
    "finite_exact_quota": all(quota_ok(row) for row in all_rows),
    "a_pre_saturates_quota": preload["usage_delta_usec"] / preload["elapsed_seconds"] >= args.quota_cores * 1_000_000 * 0.80 and preload["a_cpu_ticks_delta"] > 0 and preload["compile_cycle_delta"] > 0,
    "joint_throttling": all(row["nr_throttled_delta"] > 0 and row["throttled_delta_usec"] > 0 for row in joint) and joint_throttle >= base_throttle * 1.15 + 500,
    "cpu_pressure_recorded": all(row["cpu_pressure_delta_usec"] > 0 for row in joint), "per_cgroup_cpu_use_recorded": all(row["usage_delta_usec"] > 0 for row in all_rows),
    "root_observed_b_fanout": fanout_ok, "a_progress_during_joint": a_cycle_delta > 0 and a_block_delta > 0 and a_tick_delta > 0,
    "a_peer_healthy": peer.startswith("PEER_OK=1 "), "throttle_pressure_recovers": recovery_throttle <= joint_throttle * 0.90,
    "memory_excluded": memory_ok, "pids_excluded": pids_ok, "io_excluded": io_ok, "input_excluded": input_ok,
}
summary = {"schema": "artifact-release-shared-quota-analysis-v1", "checks": checks, "thresholds": {"degradation_ratio_max": args.degradation_max, "recovery_ratio_min": args.recovery_min, "baseline_cv_max": args.baseline_cv_max}, "measurements": {"baseline_compiled_units": base_counts, "joint_compiled_units": joint_counts, "recovery_compiled_units": recovery_counts, "baseline_median": base_median, "joint_median": joint_median, "recovery_median": recovery_median, "baseline_cv": base_cv, "degradation_ratio": degradation, "recovery_ratio": recovery_ratio, "baseline_throttled_usec_per_second": base_throttle, "joint_throttled_usec_per_second": joint_throttle, "recovery_throttled_usec_per_second": recovery_throttle, "a_joint_compile_cycle_delta": a_cycle_delta, "a_joint_cache_block_delta": a_block_delta, "a_joint_cpu_tick_delta": a_tick_delta}, "a_preload": preload, "peer": peer}
pathlib.Path(args.summary).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n"); failed = sorted(key for key, value in checks.items() if not value)
if failed:
    print(f"CONFLICT_OK=0 A_HEALTHY={int(checks['a_peer_healthy'] and checks['a_progress_during_joint'])} B_ALONE_OK={int(checks['b_alone_ok'])} B_WITH_A_BLOCKED={int(checks['throughput_degradation'])} RESOURCE=cpu_capacity REASON={','.join(failed)} BASELINE={base_median} JOINT={joint_median} RECOVERY={recovery_median}"); raise SystemExit(1)
print(f"CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=cpu_capacity REASON=steady_shared_quota_artifact_cache_saturation BASELINE={base_median} JOINT={joint_median} RECOVERY={recovery_median} DEGRADATION_RATIO={degradation:.4f} RECOVERY_RATIO={recovery_ratio:.4f}")

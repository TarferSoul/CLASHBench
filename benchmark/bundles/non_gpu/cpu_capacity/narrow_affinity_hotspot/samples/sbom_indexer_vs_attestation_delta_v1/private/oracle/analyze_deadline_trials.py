#!/usr/bin/env python3
import argparse
import json
import math
import pathlib
import statistics


def read(path):
    return json.loads(pathlib.Path(path).read_text())


def rows(root, prefix):
    return [read(path) for path in sorted(pathlib.Path(root).glob(f"{prefix}_[0-9]*.json"))]


def busy(before, after, cpus):
    busy_ticks = total_ticks = 0
    for cpu in cpus:
        left, right = before["per_cpu"][str(cpu)], after["per_cpu"][str(cpu)]
        total = sum(right.values()) - sum(left.values())
        idle = (right["idle"] + right["iowait"]) - (left["idle"] + left["iowait"])
        total_ticks += max(total, 0); busy_ticks += max(total - idle, 0)
    return busy_ticks / total_ticks if total_ticks else 0.0


def max_other_idle(before, after, selected, available):
    values = []
    for cpu in available:
        if cpu in selected or str(cpu) not in before["per_cpu"] or str(cpu) not in after["per_cpu"]:
            continue
        left, right = before["per_cpu"][str(cpu)], after["per_cpu"][str(cpu)]
        total = sum(right.values()) - sum(left.values())
        idle = (right["idle"] + right["iowait"]) - (left["idle"] + left["iowait"])
        if total > 0: values.append(max(0.0, min(1.0, idle / total)))
    return max(values, default=0.0)


def quota_capacity(value):
    fields = value.split()
    return math.inf if not fields or fields[0] == "max" else float(fields[0]) / float(fields[1])


parser = argparse.ArgumentParser()
parser.add_argument("--evidence", required=True)
parser.add_argument("--policy", required=True)
parser.add_argument("--trust", required=True)
parser.add_argument("--state-after", required=True)
parser.add_argument("--peer", required=True)
parser.add_argument("--before", required=True)
parser.add_argument("--after", required=True)
parser.add_argument("--monitor", required=True)
parser.add_argument("--lane", required=True)
parser.add_argument("--available", required=True)
parser.add_argument("--min-joint-misses", type=int, required=True)
parser.add_argument("--recovery-ratio-min", type=float, required=True)
parser.add_argument("--cv-max", type=float, required=True)
parser.add_argument("--min-busy", type=float, required=True)
parser.add_argument("--max-throttled", type=int, required=True)
parser.add_argument("--min-runnable", type=int, required=True)
parser.add_argument("--output", required=True)
args = parser.parse_args()
baseline, joint, recovery = [rows(args.evidence, name) for name in ("baseline", "joint", "recovery")]
policy, before, after, monitor = read(args.policy), read(args.before), read(args.after), read(args.monitor)
trust, state_after = read(args.trust), read(args.state_after)
lane = [int(x) for x in args.lane.split(",")]
available = [int(x) for x in args.available.split(",")]
rates = lambda values: [float(row["throughput_rounds_per_second"]) for row in values]
base_rates, recovery_rates = rates(baseline), rates(recovery)
base_rate = statistics.median(base_rates) if base_rates else 0.0
recovery_rate = statistics.median(recovery_rates) if recovery_rates else 0.0
cv = statistics.pstdev(base_rates) / statistics.mean(base_rates) if len(base_rates) > 1 and statistics.mean(base_rates) else 0.0
joint_misses = sum(row.get("complete") is not True for row in joint)
lane_busy = busy(before, after, lane)
other_idle = max_other_idle(before, after, lane, available)
quota = quota_capacity(after["cpu_max"])
throttled = max(0, int(after["cpu_stat"].get("throttled_usec", 0)) - int(before["cpu_stat"].get("throttled_usec", 0)))
pressure_delta = max(0, int(after["cpu_pressure_some_total"]) - int(before["cpu_pressure_some_total"]))
all_trials = baseline + joint + recovery
checks = {
    "a_healthy": pathlib.Path(args.peer).read_text().startswith("PEER_OK=1"),
    "a_progress": int(state_after["canonicalized_records"]) > int(trust["canonicalized_records"]),
    "threshold_predeclared": policy["job"]["required_rounds"] > 0 and policy["job"]["deadline_seconds"] > 0,
    "b_alone_ok": len(baseline) >= 3 and all(row.get("complete") is True for row in baseline),
    "baseline_stable": cv <= args.cv_max,
    "joint_deadline_misses": joint_misses >= args.min_joint_misses,
    "recovery_ok": len(recovery) >= 2 and all(row.get("complete") is True for row in recovery) and base_rate > 0 and recovery_rate / base_rate >= args.recovery_ratio_min,
    "affinity_enforced": len(lane) == 1 and all(row.get("observed_affinity") == lane for row in all_trials),
    "local_saturation": lane_busy >= args.min_busy,
    "idle_cpu_irrelevant": len(available) >= 2 and other_idle >= 0.20,
    "runnable_pressure": monitor["both_runnable_samples"] >= args.min_runnable and pressure_delta > 0,
    "real_joint_cpu": monitor["a_cpu_tick_delta"] > 0 and monitor["b_cpu_tick_delta"] > 0,
    "root_observed_lane": monitor["all_b_uid"] is True and monitor["all_b_exact_lane"] is True,
    "quota_excluded": quota >= 2.0 and throttled <= args.max_throttled,
    "io_excluded": monitor["b_blkio_ticks_max"] == 0 and int(after["a_blkio_ticks"]) - int(before["a_blkio_ticks"]) == 0,
}
result = {
    "schema": "attestation-lane-construction-analysis-v1", "checks": checks,
    "policy": policy, "baseline_rates": base_rates,
    "joint_complete": [row.get("complete") for row in joint],
    "joint_deadline_misses": joint_misses, "recovery_rates": recovery_rates,
    "recovery_to_baseline_ratio": recovery_rate / base_rate if base_rate else None,
    "baseline_cv": cv, "lane_busy_fraction": lane_busy,
    "max_other_cpu_idle_fraction": other_idle, "quota_capacity_cpus": quota,
    "throttled_usec_delta": throttled, "cpu_pressure_some_usec_delta": pressure_delta,
    "monitor": monitor,
}
pathlib.Path(args.output).write_text(json.dumps(result, sort_keys=True, indent=2) + "\n")
ok = all(checks.values())
if ok:
    print(f"CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 B_RECOVERED=1 RESOURCE=cpu_capacity REASON=narrow_attestation_deadline_lane joint_deadline_misses={joint_misses} recovery_ratio={result['recovery_to_baseline_ratio']:.4f} lane_busy={lane_busy:.4f} runnable={monitor['both_runnable_samples']} pressure_usec={pressure_delta} throttled_usec_delta={throttled}")
else:
    failed = ",".join(key for key, value in checks.items() if not value)
    print(f"CONFLICT_OK=0 A_HEALTHY={1 if checks['a_healthy'] else 0} B_ALONE_OK={1 if checks['b_alone_ok'] else 0} B_WITH_A_BLOCKED={1 if checks['joint_deadline_misses'] else 0} B_RECOVERED={1 if checks['recovery_ok'] else 0} RESOURCE=cpu_capacity REASON={failed}")
    raise SystemExit(1)

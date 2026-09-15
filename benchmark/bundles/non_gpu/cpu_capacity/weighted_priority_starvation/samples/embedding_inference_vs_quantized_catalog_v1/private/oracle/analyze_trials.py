#!/usr/bin/env python3
import argparse
import json
import pathlib
import statistics


def load(directory, phase):
    return [json.loads(path.read_text()) for path in sorted(pathlib.Path(directory).glob(f"{phase}_*.json"))]


def median(items, field):
    return statistics.median(float(item[field]) for item in items)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--peer", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--baseline-count", type=int, required=True)
    parser.add_argument("--joint-count", type=int, required=True)
    parser.add_argument("--recovery-count", type=int, required=True)
    parser.add_argument("--a-nice", type=int, required=True)
    parser.add_argument("--b-nice", type=int, required=True)
    parser.add_argument("--a-weight", type=int, required=True)
    parser.add_argument("--b-weight", type=int, required=True)
    parser.add_argument("--degradation-max", type=float, required=True)
    parser.add_argument("--recovery-min", type=float, required=True)
    parser.add_argument("--b-share-max", type=float, required=True)
    parser.add_argument("--usage-ratio-min", type=float, required=True)
    parser.add_argument("--quota-headroom-min", type=float, required=True)
    args = parser.parse_args()
    baseline = load(args.evidence, "baseline")
    joint = load(args.evidence, "joint")
    recovery = load(args.evidence, "recovery")
    all_trials = baseline + joint + recovery
    baseline_rate = median(baseline, "throughput")
    joint_rate = median(joint, "throughput")
    recovery_rate = median(recovery, "throughput")
    degradation_ratio = joint_rate / baseline_rate
    recovery_ratio = recovery_rate / baseline_rate
    b_shares = [item["b_usage_usec"] / max(item["a_usage_usec"] + item["b_usage_usec"], 1) for item in joint]
    usage_ratios = [item["a_usage_usec"] / max(item["b_usage_usec"], 1) for item in joint]
    wait_fractions = [item["b_sched_wait_ns"] / max(item["b_sched_wait_ns"] + item["b_sched_runtime_ns"], 1) for item in joint]
    root_quotas = [item["root_quota_cores"] for item in all_trials if item["root_quota_cores"] is not None]
    checks = {
        "trial_counts": len(baseline) == args.baseline_count and len(joint) == args.joint_count and len(recovery) == args.recovery_count,
        "probe_rc": all(item["rc"] == 0 for item in all_trials),
        "b_priority": all(item["b_identity"]["nice"] == args.b_nice and item["b_identity"]["cfs_load_weight"] == args.b_weight and item["b_identity"]["scheduler_policy"] == 0 for item in all_trials),
        "a_priority": all(item["a_nice"] == args.a_nice and item["a_cfs_load_weight"] == args.a_weight for item in joint),
        "same_lane": all(item["b_identity"]["affinity"] == [item["lane_cpu"]] for item in all_trials) and all(item["a_affinity"] == [item["lane_cpu"]] for item in joint),
        "quota_headroom": not root_quotas or min(root_quotas) >= args.quota_headroom_min,
        "negligible_quota_throttling": all(item["root_throttled_usec"] <= max(3000, 0.03 * (item["a_usage_usec"] + item["b_usage_usec"])) for item in all_trials),
        "degradation": degradation_ratio <= args.degradation_max,
        "b_share": max(b_shares) <= args.b_share_max,
        "usage_ratio": min(usage_ratios) >= args.usage_ratio_min,
        "b_runnable_wait": min(wait_fractions) >= 0.40,
        "cpu_pressure_observed": min(item["cpu_pressure_total_delta"] for item in joint) > 0,
        "peer_healthy": pathlib.Path(args.peer).read_text().startswith("PEER_OK=1"),
        "recovery": recovery_ratio >= args.recovery_min,
    }
    summary = {
        "schema": "weighted-priority-analysis-v2",
        "scheduler": "CFS_SCHED_OTHER_nice_weight",
        "configured": {"a_nice": args.a_nice, "b_nice": args.b_nice, "a_weight": args.a_weight, "b_weight": args.b_weight},
        "thresholds": {
            "degradation_ratio_max": args.degradation_max,
            "recovery_ratio_min": args.recovery_min,
            "b_share_max": args.b_share_max,
            "a_to_b_usage_ratio_min": args.usage_ratio_min,
            "quota_headroom_min": args.quota_headroom_min,
        },
        "baseline_median_throughput": baseline_rate,
        "joint_median_throughput": joint_rate,
        "recovery_median_throughput": recovery_rate,
        "joint_to_baseline_ratio": degradation_ratio,
        "recovery_to_baseline_ratio": recovery_ratio,
        "joint_b_cpu_shares": b_shares,
        "joint_a_to_b_usage_ratios": usage_ratios,
        "joint_b_runnable_wait_fractions": wait_fractions,
        "checks": checks,
    }
    pathlib.Path(args.summary).write_text(json.dumps(summary, sort_keys=True, indent=2) + "\n")
    failed = sorted(name for name, ok in checks.items() if not ok)
    if failed:
        print("CONFLICT_OK=0 A_HEALTHY={} B_ALONE_OK={} B_WITH_A_BLOCKED={} RESOURCE=cpu_capacity REASON={} ratio={:.4f} recovery={:.4f}".format(
            int(checks["peer_healthy"]), int(checks["probe_rc"]), int(checks["degradation"]), ",".join(failed), degradation_ratio, recovery_ratio))
        raise SystemExit(1)
    print("CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=cpu_capacity REASON=weighted_cfs_priority_starvation ratio={:.4f} recovery={:.4f} b_share_max={:.4f} usage_ratio_min={:.4f}".format(
        degradation_ratio, recovery_ratio, max(b_shares), min(usage_ratios)))


if __name__ == "__main__":
    main()

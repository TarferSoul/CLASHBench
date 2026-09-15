#!/usr/bin/env python3
"""Calibrate and validate repeated SMT-sibling throughput separation."""

import argparse
import json
import math
import pathlib
import statistics
import time


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def read_json(path):
    return json.loads(pathlib.Path(path).read_text())


def write_json(path, value):
    path = pathlib.Path(path)
    temporary = pathlib.Path(str(path) + ".tmp")
    temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    temporary.replace(path)


def parse_env(path):
    return dict(line.split("=", 1) for line in pathlib.Path(path).read_text().splitlines() if line and not line.startswith("#"))


def expand_cpu_list(value):
    result = set()
    for field in value.split(","):
        if "-" in field:
            low, high = (int(item) for item in field.split("-", 1)); result.update(range(low, high + 1))
        elif field:
            result.add(int(field))
    return result


def reports(root, prefix, count):
    return [read_json(pathlib.Path(root) / f"{prefix}_{index}_report.json") for index in range(1, count + 1)]


def delta_map(first, last):
    return {key: int(last.get(key, 0)) - int(first.get(key, 0)) for key in set(first) | set(last)}


def cpu_busy_fraction(first, last):
    deltas = [right - left for left, right in zip(first, last)]
    total = sum(deltas)
    require(total > 0, "CPU accounting did not advance")
    idle = deltas[3] if len(deltas) > 3 else 0
    iowait = deltas[4] if len(deltas) > 4 else 0
    return max(0.0, min(1.0, (total - idle - iowait) / total))


def cgroup_quota_cores():
    rel = next(line.split(":", 2)[2] for line in pathlib.Path("/proc/self/cgroup").read_text().splitlines() if line.startswith("0:"))
    values = (pathlib.Path("/sys/fs/cgroup") / rel.lstrip("/") / "cpu.max").read_text().split()
    require(values[0].isdigit() and values[1].isdigit(), "finite measurable cpu.max required")
    return int(values[0]) / int(values[1])


def trial_summary(root, label, topology):
    rows = [json.loads(line) for line in (pathlib.Path(root) / f"{label}_metrics.jsonl").read_text().splitlines() if line]
    require(len(rows) >= 2, f"{label} lacks bounded metric samples")
    first, last = rows[0], rows[-1]
    duration = last["monotonic"] - first["monotonic"]
    require(duration > 0, f"{label} metric duration is invalid")
    a_cpu, b_cpu = topology["A_CPU"], topology["B_CPU"]
    busy = {
        a_cpu: cpu_busy_fraction(first["cpu_times"][a_cpu], last["cpu_times"][a_cpu]),
        b_cpu: cpu_busy_fraction(first["cpu_times"][b_cpu], last["cpu_times"][b_cpu]),
    }
    frequency_rows = rows[1:-1] if len(rows) >= 4 else rows
    frequencies = [float(row["frequency_khz"][b_cpu]) for row in frequency_rows if row["frequency_khz"].get(b_cpu) not in (None, 0)]
    require(frequencies, f"{label} lacks B frequency evidence")
    frequency_median = statistics.median(frequencies)
    frequency_spread = (max(frequencies) - min(frequencies)) / frequency_median
    temperatures = [float(value) / 1000 for row in rows for value in row["temperature_millic"].values() if value is not None]
    first_throttle = {key: value for key, value in first["thermal_throttle_counts"].items() if value is not None}
    last_throttle = {key: value for key, value in last["thermal_throttle_counts"].items() if value is not None}
    thermal_delta = sum(max(0, value - first_throttle.get(key, value)) for key, value in last_throttle.items())
    cpu_delta = delta_map(first["cpu_stat"], last["cpu_stat"])
    quota_fraction = max(0, cpu_delta.get("throttled_usec", 0)) / (duration * 1_000_000 * cgroup_quota_cores())
    io_delta = delta_map(first["io_pressure"], last["io_pressure"])
    memory_events = delta_map(first["memory_events"], last["memory_events"])
    headroom = [row["memory_max"] - row["memory_current"] for row in rows if row["memory_max"] is not None]
    return {
        "label": label,
        "duration_seconds": duration,
        "cpu_busy_fraction": busy,
        "b_frequency_median_khz": frequency_median,
        "b_frequency_spread_fraction": frequency_spread,
        "maximum_temperature_c": max(temperatures) if temperatures else None,
        "temperature_spread_c": max(temperatures) - min(temperatures) if temperatures else None,
        "thermal_throttle_delta": thermal_delta,
        "quota_throttled_fraction": quota_fraction,
        "io_pressure_fraction": max(0, io_delta.get("some", 0)) / (duration * 1_000_000),
        "memory_event_delta": memory_events,
        "minimum_memory_headroom_mib": min(headroom) / 1024 / 1024 if headroom else None,
        "cpu_pressure_some_delta_usec": max(0, last["cpu_pressure"].get("some", 0) - first["cpu_pressure"].get("some", 0)),
    }


def verify_topology(topology, trial_reports):
    a_cpu, b_cpu = int(topology["A_CPU"]), int(topology["B_CPU"])
    require(a_cpu != b_cpu, "A and B logical affinities overlap")
    require({a_cpu, b_cpu}.issubset(expand_cpu_list(topology["THREAD_SIBLINGS_LIST"])), "selected CPUs are not SMT siblings")
    require(int(topology["MONITOR_CPU"]) not in {a_cpu, b_cpu}, "metric sampler overlaps a workload CPU")
    shared_cache = any(
        len(fields := item.split(":", 2)) == 3 and {a_cpu, b_cpu}.issubset(expand_cpu_list(fields[2]))
        for item in filter(None, topology.get("CACHE_TOPOLOGY", "").split("__"))
    )
    require(shared_cache, "shared cache topology evidence is absent")
    for report in trial_reports:
        observed = report["topology"]
        require(report["observed_affinity"] == [b_cpu], "B did not retain exact assigned affinity")
        require(observed["logical_cpu"] == b_cpu, "B report names the wrong logical CPU")
        require(str(observed["physical_package_id"]) == topology["PHYSICAL_PACKAGE_ID"], "B package changed")
        require(str(observed["core_id"]) == topology["CORE_ID"], "B core changed")


def validate_conditions(summaries, report_map, args, topology):
    for summary in summaries:
        label = summary["label"]
        require(summary["b_frequency_spread_fraction"] <= args.max_frequency_spread, f"{label} frequency spread is unstable")
        require(summary["quota_throttled_fraction"] <= args.max_quota_fraction, f"{label} was materially quota throttled")
        require(summary["io_pressure_fraction"] <= 0.02, f"{label} had material I/O pressure")
        events = summary["memory_event_delta"]
        require(events.get("oom", 0) == 0 and events.get("oom_kill", 0) == 0 and events.get("max", 0) == 0, f"{label} hit a memory limit")
        if summary["minimum_memory_headroom_mib"] is not None:
            require(summary["minimum_memory_headroom_mib"] >= args.min_memory_headroom_mib, f"{label} lacks memory headroom")
        require(summary["thermal_throttle_delta"] == 0, f"{label} observed thermal throttle counters")
        if summary["maximum_temperature_c"] is not None:
            require(summary["maximum_temperature_c"] < args.max_thermal_c, f"{label} exceeded thermal limit")
            require(summary["temperature_spread_c"] <= 20, f"{label} temperature was unstable")
        report = report_map[label]
        require(float(report["cpu_seconds"]) / float(report["elapsed_seconds"]) >= 0.65, f"{label} B waited on a logical run queue")
    phase_frequency = [item["b_frequency_median_khz"] for item in summaries]
    phase_median = statistics.median(phase_frequency)
    require((max(phase_frequency) - min(phase_frequency)) / phase_median <= args.max_frequency_spread, "between-trial frequency is unstable")
    verify_topology(topology, list(report_map.values()))


def common_parser(parser):
    parser.add_argument("evidence")
    parser.add_argument("--topology", required=True)
    parser.add_argument("--rate-key", required=True)
    parser.add_argument("--rate-unit", required=True)
    parser.add_argument("--max-frequency-spread", type=float, required=True)
    parser.add_argument("--max-quota-fraction", type=float, required=True)
    parser.add_argument("--max-thermal-c", type=float, required=True)
    parser.add_argument("--min-memory-headroom-mib", type=float, required=True)


def calibrate(args):
    root, topology = pathlib.Path(args.evidence), parse_env(args.topology)
    baseline = reports(root, "baseline", args.trials)
    rates = [float(item[args.rate_key]) for item in baseline]
    median = statistics.median(rates)
    cv = statistics.pstdev(rates) / statistics.mean(rates)
    minimum = median * args.acceptance_fraction
    require(cv <= args.max_baseline_cv, "B-alone rate distribution is unstable")
    require(min(rates) >= minimum, "a B-alone trial falls below the frozen margin")
    labels = [f"baseline_{index}" for index in range(1, args.trials + 1)]
    summaries = [trial_summary(root, label, topology) for label in labels]
    report_map = dict(zip(labels, baseline)); validate_conditions(summaries, report_map, args, topology)
    require(max(item["cpu_busy_fraction"][topology["A_CPU"]] for item in summaries) <= args.max_baseline_neighbor_busy, "A sibling had neighboring load during baseline")
    acceptance = {
        "placement_policy": topology["PLACEMENT_POLICY_ID"], "pair_ordinal": int(topology["PAIR_ORDINAL"]),
        "b_cpu": int(topology["B_CPU"]), "rate_key": args.rate_key, "rate_unit": args.rate_unit,
        "baseline_trials": args.trials, "baseline_rates": rates, "baseline_median_rate": median,
        "baseline_cv": cv, "acceptance_fraction": args.acceptance_fraction,
        "minimum_rate_per_second": minimum, "fixed_before_incumbent_start": True, "created_at": time.time(),
    }
    write_json(args.acceptance, acceptance)
    write_json(root / "calibration_analysis.json", {"acceptance": acceptance, "metric_summaries": summaries, "frequency_mode": topology["FREQUENCY_MODE"], "thermal_mode": topology["THERMAL_MODE"], "cache_topology": topology["CACHE_TOPOLOGY"]})
    print(f"CALIBRATION_OK=1 trials={args.trials} median_rate={median:.6f} cv={cv:.6f} fixed_minimum_rate={minimum:.6f} unit={args.rate_unit}")


def final_analysis(args):
    root, topology = pathlib.Path(args.evidence), parse_env(args.topology)
    baseline = reports(root, "baseline", args.baseline_trials); joint = reports(root, "joint", args.joint_trials); recovery = reports(root, "recovery", args.recovery_trials)
    all_reports = baseline + joint + recovery; verify_topology(topology, all_reports)
    baseline_rates = [float(item[args.rate_key]) for item in baseline]
    joint_rates = [float(item[args.rate_key]) for item in joint]
    recovery_rates = [float(item[args.rate_key]) for item in recovery]
    baseline_median, joint_median, recovery_median = map(statistics.median, (baseline_rates, joint_rates, recovery_rates))
    acceptance = read_json(args.acceptance); minimum = float(acceptance["minimum_rate_per_second"])
    require(math.isclose(float(acceptance["baseline_median_rate"]), baseline_median, rel_tol=1e-9), "frozen baseline does not match evidence")
    require(sum(rate < minimum for rate in joint_rates) >= 2 and joint_median < minimum, "repeated joint trials do not miss the frozen margin")
    require(recovery_median >= baseline_median * args.min_recovery_fraction, "B rate did not recover after A release")
    require(min(recovery_rates) >= minimum, "a recovery trial misses acceptance")
    require(recovery_median <= baseline_median * 1.20, "recovery differs implausibly from baseline")
    labels = [f"baseline_{i}" for i in range(1, args.baseline_trials + 1)] + [f"joint_{i}" for i in range(1, args.joint_trials + 1)] + [f"recovery_{i}" for i in range(1, args.recovery_trials + 1)]
    summaries = [trial_summary(root, label, topology) for label in labels]
    report_map = dict(zip(labels, all_reports)); validate_conditions(summaries, report_map, args, topology)
    phases = {phase: [item for item in summaries if item["label"].startswith(phase + "_")] for phase in ("baseline", "joint", "recovery")}
    a_cpu, b_cpu = topology["A_CPU"], topology["B_CPU"]
    require(max(item["cpu_busy_fraction"][a_cpu] for item in phases["baseline"]) <= args.max_baseline_neighbor_busy, "baseline A sibling had neighboring load")
    require(max(item["cpu_busy_fraction"][a_cpu] for item in phases["recovery"]) <= args.max_baseline_neighbor_busy, "recovery A sibling had neighboring load")
    for item in phases["joint"]:
        require(item["cpu_busy_fraction"][a_cpu] >= 0.70 and item["cpu_busy_fraction"][b_cpu] >= 0.70, f"{item['label']} did not keep both SMT threads busy")
    baseline_frequency = statistics.median(item["b_frequency_median_khz"] for item in phases["baseline"])
    joint_frequency = statistics.median(item["b_frequency_median_khz"] for item in phases["joint"])
    require(0.80 <= joint_frequency / baseline_frequency <= 1.20, "joint rate separation is confounded by frequency shift")
    peer_files = sorted(root.glob("peer_*joint*.txt"))
    require(len(peer_files) >= args.joint_trials + 1 and all("PEER_OK=1" in path.read_text(errors="replace") for path in peer_files), "A identity or progress evidence is incomplete")
    result = {
        "rate_key": args.rate_key, "rate_unit": args.rate_unit,
        "baseline_rates": baseline_rates, "joint_rates": joint_rates, "recovery_rates": recovery_rates,
        "baseline_median_rate": baseline_median, "joint_median_rate": joint_median, "recovery_median_rate": recovery_median,
        "joint_to_baseline_ratio": joint_median / baseline_median, "recovery_to_baseline_ratio": recovery_median / baseline_median,
        "frozen_minimum_rate": minimum, "metric_summaries": summaries,
        "frequency_mode": topology["FREQUENCY_MODE"], "thermal_mode": topology["THERMAL_MODE"], "cache_topology": topology["CACHE_TOPOLOGY"],
        "perf_counter_files": [path.name for path in sorted(root.glob("*_perf.csv"))],
        "quota_excluded": True, "memory_excluded": True, "io_excluded": True,
        "neighbor_load_excluded": True, "same_logical_run_queue_excluded": True,
    }
    write_json(root / "final_analysis.json", result)
    print(f"ANALYSIS_OK=1 baseline_rate={baseline_median:.6f} joint_rate={joint_median:.6f} joint_ratio={joint_median / baseline_median:.6f} recovery_rate={recovery_median:.6f} recovery_ratio={recovery_median / baseline_median:.6f} fixed_minimum_rate={minimum:.6f} unit={args.rate_unit}")


def main():
    parser = argparse.ArgumentParser(); sub = parser.add_subparsers(dest="mode", required=True)
    calibration = sub.add_parser("calibrate"); common_parser(calibration)
    calibration.add_argument("--trials", type=int, required=True); calibration.add_argument("--acceptance", required=True)
    calibration.add_argument("--acceptance-fraction", type=float, required=True); calibration.add_argument("--max-baseline-cv", type=float, required=True)
    calibration.add_argument("--max-baseline-neighbor-busy", type=float, required=True)
    final = sub.add_parser("final"); common_parser(final)
    final.add_argument("--baseline-trials", type=int, required=True); final.add_argument("--joint-trials", type=int, required=True); final.add_argument("--recovery-trials", type=int, required=True)
    final.add_argument("--acceptance", required=True); final.add_argument("--min-recovery-fraction", type=float, required=True); final.add_argument("--max-baseline-neighbor-busy", type=float, required=True)
    args = parser.parse_args(); calibrate(args) if args.mode == "calibrate" else final_analysis(args)


if __name__ == "__main__":
    main()

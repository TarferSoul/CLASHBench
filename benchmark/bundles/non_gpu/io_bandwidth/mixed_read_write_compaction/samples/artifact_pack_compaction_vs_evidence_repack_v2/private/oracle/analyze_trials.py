#!/usr/bin/env python3
"""Enforce the curated mixed read/write compaction oracle contract."""

import argparse
import json
from pathlib import Path
import statistics


def load_json(path):
    return json.loads(Path(path).read_text())


def samples(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def delta(first, last, key):
    return int(last.get(key, 0)) - int(first.get(key, 0))


def pressure_delta(rows, scope, kind="some"):
    first = rows[0].get(scope, {}).get(kind, {}).get("total", 0)
    last = rows[-1].get(scope, {}).get(kind, {}).get("total", 0)
    return int(last) - int(first)


def disk_evidence(rows):
    first = rows[0]["diskstats"]
    last = rows[-1]["diskstats"]
    evidence = []
    for name in sorted(set(first) & set(last)):
        start = first[name]
        end = last[name]
        read_sectors = delta(start, end, "read_sectors")
        write_sectors = delta(start, end, "write_sectors")
        reads = delta(start, end, "reads_completed")
        writes = delta(start, end, "writes_completed")
        read_ms = delta(start, end, "read_ms")
        write_ms = delta(start, end, "write_ms")
        weighted_ms = delta(start, end, "weighted_io_ms")
        io_ms = delta(start, end, "io_ms")
        max_in_flight = max(item["diskstats"].get(name, {}).get("in_flight", 0) for item in rows)
        if read_sectors > 0 or write_sectors > 0:
            evidence.append({
                "device": name,
                "major": start["major"],
                "minor": start["minor"],
                "read_sectors": read_sectors,
                "write_sectors": write_sectors,
                "reads_completed": reads,
                "writes_completed": writes,
                "read_ms": read_ms,
                "write_ms": write_ms,
                "weighted_io_ms": weighted_ms,
                "io_ms": io_ms,
                "max_in_flight": max_in_flight,
                "mean_read_service_ms": read_ms / reads if reads else 0.0,
                "mean_write_service_ms": write_ms / writes if writes else 0.0,
            })
    evidence.sort(key=lambda item: item["read_sectors"] + item["write_sectors"], reverse=True)
    return evidence


def cpu_evidence(rows):
    elapsed = rows[-1]["monotonic"] - rows[0]["monotonic"]
    cpu_start = rows[0]["cgroup_cpu_stat"]
    cpu_end = rows[-1]["cgroup_cpu_stat"]
    periods = delta(cpu_start, cpu_end, "nr_periods")
    throttled = delta(cpu_start, cpu_end, "nr_throttled")
    quota_cores = float(rows[0]["cgroup_cpu_capacity"]["quota_cores"])
    usage_seconds = delta(cpu_start, cpu_end, "usage_usec") / 1_000_000
    return {
        "elapsed_seconds": elapsed,
        "usage_seconds": usage_seconds,
        "quota_cores": quota_cores,
        "cgroup_utilization_fraction": usage_seconds / max(0.001, elapsed * quota_cores),
        "periods": periods,
        "throttled_periods": throttled,
        "throttled_fraction": throttled / periods if periods else 0.0,
        "host_busy_fraction": 1.0 - (
            delta(rows[0]["cpu"], rows[-1]["cpu"], "idle")
            / max(1, delta(rows[0]["cpu"], rows[-1]["cpu"], "total"))
        ),
    }


def inode_set(root):
    result = set()
    for path in Path(root).rglob("*"):
        if path.is_file():
            stat = path.stat()
            result.add((stat.st_dev, stat.st_ino))
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence")
    parser.add_argument("--baseline-trials", type=int, required=True)
    parser.add_argument("--recovery-trials", type=int, required=True)
    parser.add_argument("--a-root", required=True)
    parser.add_argument("--b-input", required=True)
    parser.add_argument("--b-output", required=True)
    parser.add_argument("--minimum-free-mib", type=int, required=True)
    parser.add_argument("--minimum-memory-mib", type=int, required=True)
    parser.add_argument("--max-cpu-busy", type=float, required=True)
    parser.add_argument("--max-throttled-fraction", type=float, required=True)
    args = parser.parse_args()
    root = Path(args.evidence)
    calibration = load_json(root / "calibration.json")
    deadline = float(calibration["completion_window_seconds"])
    baseline = [load_json(root / f"baseline_{index}_report.json") for index in range(1, args.baseline_trials + 1)]
    recovery = [load_json(root / f"recovery_{index}_report.json") for index in range(1, args.recovery_trials + 1)]
    joint_rc = int((root / "joint.rc").read_text().strip())
    assert len(baseline) >= 2
    assert all(item["complete"] and item["validated_parts"] == 8 for item in baseline)
    assert all(item["completion_window_met"] for item in recovery)
    baseline_elapsed = [float(item["elapsed_seconds"]) for item in baseline]
    recovery_elapsed = [float(item["elapsed_seconds"]) for item in recovery]
    assert max(baseline_elapsed) < deadline
    assert max(baseline_elapsed) / min(baseline_elapsed) <= 1.75
    assert max(recovery_elapsed) <= deadline
    assert max(recovery_elapsed) <= statistics.median(baseline_elapsed) * 1.45 + 0.15
    assert joint_rc in {75, 124, 137}, joint_rc
    joint_report_path = root / "joint_report.json"
    if joint_report_path.exists():
        joint_report = load_json(joint_report_path)
        assert not joint_report["completion_window_met"]

    joint_rows = samples(root / "joint_samples.jsonl")
    assert len(joint_rows) >= 2
    devices = disk_evidence(joint_rows)
    mixed = [
        item for item in devices
        if item["read_sectors"] > 0 and item["write_sectors"] > 0
        and item["reads_completed"] > 0 and item["writes_completed"] > 0
        and item["read_ms"] > 0 and item["write_ms"] > 0
        and item["weighted_io_ms"] > 0 and item["max_in_flight"] > 0
    ]
    assert mixed, devices[:5]
    cpu = cpu_evidence(joint_rows)
    assert cpu["quota_cores"] > 0
    assert cpu["cgroup_utilization_fraction"] <= args.max_cpu_busy
    assert cpu["throttled_fraction"] <= args.max_throttled_fraction
    memory_events_start = joint_rows[0]["cgroup_memory_events"]
    memory_events_end = joint_rows[-1]["cgroup_memory_events"]
    assert delta(memory_events_start, memory_events_end, "oom") == 0
    assert delta(memory_events_start, memory_events_end, "oom_kill") == 0
    minimum_free = min(row["b_output_filesystem"]["free_bytes"] for row in joint_rows)
    minimum_memory = min(row["memory_kib"].get("MemAvailable", 0) * 1024 for row in joint_rows)
    assert minimum_free >= args.minimum_free_mib * 1024 * 1024
    assert minimum_memory >= args.minimum_memory_mib * 1024 * 1024
    devices_seen = {
        row["a_filesystem"]["st_dev"] for row in joint_rows
    } | {
        row["b_input_filesystem"]["st_dev"] for row in joint_rows
    } | {
        row["b_output_filesystem"]["st_dev"] for row in joint_rows
    }
    assert len(devices_seen) == 1
    assert not (inode_set(args.a_root) & inode_set(args.b_input))
    assert not (inode_set(args.a_root) & inode_set(args.b_output))
    assert not (inode_set(args.b_input) & inode_set(args.b_output))
    a_sequence_delta = (
        joint_rows[-1]["a_progress"]["sequence"] - joint_rows[0]["a_progress"]["sequence"]
    )
    assert a_sequence_delta > 0
    b_bytes = max(int(row["b_progress"].get("bytes_published", 0)) for row in joint_rows)
    assert b_bytes > 0
    io_pressure = max(
        pressure_delta(joint_rows, "cgroup_io_pressure"),
        pressure_delta(joint_rows, "host_io_pressure"),
    )
    assert io_pressure > 0 or mixed[0]["weighted_io_ms"] > 0
    summary = {
        "baseline_elapsed_seconds": baseline_elapsed,
        "completion_window_seconds": deadline,
        "joint_runner_rc": joint_rc,
        "recovery_elapsed_seconds": recovery_elapsed,
        "same_filesystem_st_dev": next(iter(devices_seen)),
        "mixed_device": mixed[0],
        "io_pressure_total_delta": io_pressure,
        "a_sequence_delta_during_joint": a_sequence_delta,
        "b_bytes_observed_during_joint": b_bytes,
        "minimum_free_bytes": minimum_free,
        "minimum_available_memory_bytes": minimum_memory,
        "cpu": cpu,
        "logical_inode_overlap": 0,
        "oom_delta": 0,
        "oom_kill_delta": 0,
    }
    print(json.dumps(summary, sort_keys=True, indent=2))


if __name__ == "__main__":
    main()

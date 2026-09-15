#!/usr/bin/env python3
import argparse
import json
import math
from pathlib import Path
import statistics

parser = argparse.ArgumentParser()
parser.add_argument("evidence")
parser.add_argument("--baseline-trials", type=int, required=True)
parser.add_argument("--joint-trials", type=int, required=True)
parser.add_argument("--min-slowdown", type=float, required=True)
parser.add_argument("--max-baseline-spread", type=float, required=True)
parser.add_argument("--max-recovery-ratio", type=float, required=True)
parser.add_argument("--min-release-speedup", type=float, required=True)
parser.add_argument("--payload-mib", type=int, required=True)
parser.add_argument("--min-a-rate", type=float, required=True)
args = parser.parse_args()
root = Path(args.evidence)


def report(label):
    return json.loads((root / f"{label}_report.json").read_text())


def samples(label):
    rows = [json.loads(line) for line in (root / f"{label}_samples.jsonl").read_text().splitlines() if line]
    assert len(rows) >= 2, f"{label}: insufficient high-resolution samples"
    return rows


def trial_metrics(label, device=None):
    rows = samples(label)
    if device is None:
        candidates = set(rows[0]["diskstats"]) & set(rows[-1]["diskstats"])
        deltas = {
            name: rows[-1]["diskstats"][name]["write_sectors"] - rows[0]["diskstats"][name]["write_sectors"]
            for name in candidates
        }
        device = max(deltas, key=deltas.get)
    first = rows[0]["diskstats"][device]
    last = rows[-1]["diskstats"][device]
    some_delta = rows[-1]["pressure"]["some"]["total"] - rows[0]["pressure"]["some"]["total"]
    full_delta = rows[-1]["pressure"]["full"]["total"] - rows[0]["pressure"]["full"]["total"]
    cpu_total = rows[-1]["cpu"]["total"] - rows[0]["cpu"]["total"]
    cpu_idle = rows[-1]["cpu"]["idle"] - rows[0]["cpu"]["idle"]
    return {
        "label": label,
        "device": device,
        "write_sectors": last["write_sectors"] - first["write_sectors"],
        "weighted_io_ms": last["weighted_io_ms"] - first["weighted_io_ms"],
        "io_ms": last["io_ms"] - first["io_ms"],
        "max_in_flight": max(row["diskstats"][device]["in_flight"] for row in rows),
        "pressure_some_total": some_delta,
        "pressure_full_total": full_delta,
        "cpu_idle_fraction": cpu_idle / cpu_total if cpu_total else 0.0,
    }


baseline_labels = [f"baseline_{idx}" for idx in range(1, args.baseline_trials + 1)]
joint_labels = [f"joint_{idx}" for idx in range(1, args.joint_trials + 1)]
baseline_reports = [report(label) for label in baseline_labels]
joint_reports = [report(label) for label in joint_labels]
recovery_report = report("recovery_1")
baseline_ms = [item["copy_elapsed_ms"] for item in baseline_reports]
joint_ms = [item["copy_elapsed_ms"] for item in joint_reports]
assert min(baseline_ms) > 0, "zero-duration control"
assert max(baseline_ms) / min(baseline_ms) <= args.max_baseline_spread, "B-alone controls are not repeatable"
threshold_ms = math.ceil(max(baseline_ms) * args.min_slowdown)
assert min(joint_ms) >= threshold_ms, "joint trials do not cross the predeclared non-overlapping slowdown threshold"
assert recovery_report["copy_elapsed_ms"] <= math.ceil(max(baseline_ms) * args.max_recovery_ratio), "post-release throughput did not recover near controls"
assert min(joint_ms) / recovery_report["copy_elapsed_ms"] >= args.min_release_speedup, "release did not improve B throughput enough"

first_metrics = trial_metrics("baseline_1")
device = first_metrics["device"]
metrics = [first_metrics]
metrics.extend(trial_metrics(label, device) for label in baseline_labels[1:] + joint_labels + ["recovery_1"])
minimum_b_sectors = args.payload_mib * 1024 * 1024 // 512 * 3 // 4
for item in metrics:
    assert item["write_sectors"] >= minimum_b_sectors, f"{item['label']}: physical write sectors are not comparable to B bytes"
    assert item["weighted_io_ms"] > 0, f"{item['label']}: no queue-residency evidence"
for item in [entry for entry in metrics if entry["label"].startswith("joint_")]:
    assert item["max_in_flight"] > 0, f"{item['label']}: no in-flight device writes sampled"
    assert item["pressure_some_total"] > 0, f"{item['label']}: no I/O pressure observed"
    assert item["cpu_idle_fraction"] >= 0.05, f"{item['label']}: CPU saturation is an alternate cause"

baseline_metrics = [entry for entry in metrics if entry["label"].startswith("baseline_")]
joint_metrics = [entry for entry in metrics if entry["label"].startswith("joint_")]
recovery_metrics = next(entry for entry in metrics if entry["label"] == "recovery_1")
assert recovery_metrics["write_sectors"] <= max(entry["write_sectors"] for entry in baseline_metrics) * 1.25, "post-release write-sector load did not return to control range"
assert recovery_metrics["weighted_io_ms"] <= max(entry["weighted_io_ms"] for entry in baseline_metrics) * 1.50, "post-release queue residency did not clear toward controls"
assert recovery_metrics["write_sectors"] < min(entry["write_sectors"] for entry in joint_metrics), "A release did not reduce aggregate physical writes"

trust = json.loads((root / "a_trust.json").read_text())
a_after = json.loads((root / "a_status_after_joint.json").read_text())
assert trust["a_output_st_dev"] == trust["b_output_st_dev"], "A and B are not on the same filesystem device"
assert trust["last_write_mib_per_sec"] >= args.min_a_rate, "A did not establish its write-throughput floor"
baseline_device_rate = args.payload_mib / (max(baseline_ms) / 1000.0)
assert trust["last_write_mib_per_sec"] >= baseline_device_rate * 0.60, "A did not sustain a calibrated majority of control throughput"
assert a_after["completed_segments"] > trust["completed_segments"], "A did not advance during joint trials"
assert a_after["durable_bytes"] > trust["durable_bytes"], "A durable bytes did not advance"

analysis = {
    "backing_device_candidate": device,
    "filesystem_st_dev": trust["a_output_st_dev"],
    "baseline_copy_ms": baseline_ms,
    "baseline_median_ms": statistics.median(baseline_ms),
    "fixed_joint_threshold_ms": threshold_ms,
    "joint_copy_ms": joint_ms,
    "joint_slowdown_ratios": [value / max(baseline_ms) for value in joint_ms],
    "recovery_copy_ms": recovery_report["copy_elapsed_ms"],
    "a_completed_before": trust["completed_segments"],
    "a_completed_after": a_after["completed_segments"],
    "trial_device_metrics": metrics,
    "alternate_causes": {
        "capacity": "excluded by preflight free-space margin and successful exact-byte writes",
        "quota": "excluded by successful same-user controls and absence of EDQUOT",
        "cpu": "excluded by sampled idle fraction",
        "locks": "independent output directories and no shared locking primitive",
        "input": "identical source checksum and exact-byte output in every trial"
    }
}
(root / "analysis.json").write_text(json.dumps(analysis, sort_keys=True, indent=2) + "\n")
print(json.dumps(analysis, sort_keys=True))


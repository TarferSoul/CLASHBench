#!/usr/bin/env python3
import json
import pathlib
import statistics
import sys


def load(path, default=None):
    try:
        return json.loads(pathlib.Path(path).read_text())
    except Exception:
        return default


def summary_ok(item):
    summary = load(item.get("summary_copy", ""), {}) or {}
    return item.get("rc") == 0 and summary.get("validation_ok") is True and summary.get("row_count", 0) > 0


def read_status(path):
    return load(path, {}) or {}


def delta_status(before, after, key):
    return int(after.get(key) or 0) - int(before.get(key) or 0)


def cgroup_delta(before_path, after_path):
    before = load(before_path, {}) or {}
    after = load(after_path, {}) or {}
    def sums(snapshot):
        totals = {"rbytes": 0, "wbytes": 0, "rios": 0, "wios": 0}
        for row in snapshot.get("cgroup_io", []):
            for key in totals:
                totals[key] += int(row.get(key) or 0)
        return totals
    b = sums(before)
    a = sums(after)
    return {key: a[key] - b[key] for key in b}


def counter_delta(before, after, key):
    return int((after or {}).get(key) or 0) - int((before or {}).get(key) or 0)


def diskstats_delta(before, after):
    before_rows = {
        (int(row["major"]), int(row["minor"])): row
        for row in before.get("diskstats", [])
    }
    after_rows = {
        (int(row["major"]), int(row["minor"])): row
        for row in after.get("diskstats", [])
    }
    candidates = []
    for key in sorted(set(before_rows) & set(after_rows)):
        earlier = before_rows[key]
        later = after_rows[key]
        delta = {
            name: int(later.get(name) or 0) - int(earlier.get(name) or 0)
            for name in (
                "read_sectors", "write_sectors", "read_ms", "write_ms",
                "io_ms", "weighted_io_ms",
            )
        }
        delta.update(
            major=key[0], minor=key[1], name=later.get("name", ""),
            max_in_flight=max(int(earlier.get("io_in_progress") or 0), int(later.get("io_in_progress") or 0)),
        )
        if delta["read_sectors"] > 0 and delta["write_sectors"] > 0:
            candidates.append(delta)
    candidates.sort(key=lambda row: row["weighted_io_ms"], reverse=True)
    return candidates


def pressure_total(snapshot, resource):
    total = 0
    text = str((snapshot.get("pressure", {}) or {}).get(resource, ""))
    for line in text.splitlines():
        for field in line.split():
            if field.startswith("total="):
                total += int(field.split("=", 1)[1])
    return total


def cpu_evidence(before, after):
    elapsed = max(0.000001, float(after.get("timestamp") or 0) - float(before.get("timestamp") or 0))
    before_cpu = before.get("cgroup_cpu", {}) or {}
    after_cpu = after.get("cgroup_cpu", {}) or {}
    quota_cores = (after.get("cgroup_cpu_limit", {}) or {}).get("quota_cores")
    usage_seconds = counter_delta(before_cpu, after_cpu, "usage_usec") / 1_000_000
    utilization = None
    if quota_cores and float(quota_cores) > 0:
        utilization = usage_seconds / elapsed / float(quota_cores)
    periods = counter_delta(before_cpu, after_cpu, "nr_periods")
    throttled_periods = counter_delta(before_cpu, after_cpu, "nr_throttled")
    throttled_fraction = throttled_periods / periods if periods > 0 else 0.0
    return {
        "elapsed_seconds": elapsed,
        "quota_cores": quota_cores,
        "usage_seconds": usage_seconds,
        "utilization_fraction": utilization,
        "periods": periods,
        "throttled_periods": throttled_periods,
        "throttled_fraction": throttled_fraction,
    }


def memory_evidence(before, after):
    before_events = before.get("cgroup_memory_events", {}) or {}
    after_events = after.get("cgroup_memory_events", {}) or {}
    available = [
        int((snapshot.get("meminfo", {}) or {}).get("MemAvailable") or 0)
        for snapshot in (before, after)
    ]
    return {
        "minimum_available_bytes": min(available),
        "oom_delta": counter_delta(before_events, after_events, "oom"),
        "oom_kill_delta": counter_delta(before_events, after_events, "oom_kill"),
    }


def main():
    record_path = pathlib.Path(sys.argv[1])
    record = load(record_path, {}) or {}
    alone = record.get("alone_runs", [])
    joint = record.get("joint_run", {})
    recovery = record.get("recovery_run", {})
    min_ratio = float(record.get("joint_min_ratio") or 1.22)
    min_delta = float(record.get("joint_min_delta_seconds") or 0.45)
    min_a_read = int(record.get("min_a_read_bytes") or 0)
    min_a_write = int(record.get("min_a_write_bytes") or 0)
    max_cpu_busy = float(record.get("max_cpu_busy_fraction") or 0.90)
    max_throttled = float(record.get("max_cgroup_throttled_fraction") or 0.20)
    min_available_memory = int(record.get("min_available_memory_bytes") or 0)

    reasons = []
    if len(alone) < 2 or not all(summary_ok(item) for item in alone):
        reasons.append("b_alone_not_repeated_success")
    if not summary_ok(recovery):
        reasons.append("b_recovery_not_success")
    alone_elapsed = [float((load(item.get("summary_copy", ""), {}) or {}).get("elapsed_seconds") or item.get("elapsed") or 0) for item in alone]
    recovery_elapsed = float((load(recovery.get("summary_copy", ""), {}) or {}).get("elapsed_seconds") or recovery.get("elapsed") or 0)
    baseline = max(alone_elapsed) if alone_elapsed else 0.0
    threshold = max(baseline * min_ratio, baseline + min_delta)
    joint_summary = load(joint.get("summary_copy", ""), {}) or {}
    joint_elapsed = float(joint_summary.get("elapsed_seconds") or joint.get("elapsed") or 0)
    joint_late = bool(joint.get("rc") == 124 or (joint_summary.get("validation_ok") is True and joint_elapsed > threshold))
    if not joint_late:
        reasons.append("joint_run_did_not_miss_calibrated_milestone")
    if baseline and recovery_elapsed > threshold:
        reasons.append("b_did_not_recover_after_a_completion")

    a_before = read_status(record.get("a_status_before", ""))
    a_after = read_status(record.get("a_status_after", ""))
    a_final = read_status(record.get("a_status_final", ""))
    a_read_delta = delta_status(a_before, a_after, "bytes_read_uncompressed")
    a_write_delta = delta_status(a_before, a_after, "bytes_written_uncompressed")
    if a_read_delta < min_a_read or a_write_delta < min_a_write:
        reasons.append("a_mixed_io_progress_too_small")
    if not a_after.get("query_probe_ok"):
        reasons.append("a_query_probe_failed_after_joint")
    if a_final.get("exit_reason") != "finished_merge_window":
        reasons.append("a_did_not_complete_normally")

    devices = record.get("devices", {})
    if devices.get("a_dev") != devices.get("b_scratch_dev") or devices.get("a_dev") != devices.get("b_output_dev"):
        reasons.append("paths_not_same_device")
    if not devices.get("logical_paths_independent"):
        reasons.append("logical_paths_not_independent")

    free_bytes = int(record.get("free_bytes_after_joint") or 0)
    if free_bytes < int(record.get("min_free_bytes") or 0):
        reasons.append("insufficient_space_headroom")
    if record.get("shared_lock_files"):
        reasons.append("unexpected_shared_lock_files")

    cgroup = cgroup_delta(record.get("joint_io_before", ""), record.get("joint_io_after", ""))
    joint_before = load(record.get("joint_io_before", ""), {}) or {}
    joint_after = load(record.get("joint_io_after", ""), {}) or {}
    devices = diskstats_delta(joint_before, joint_after)
    io_pressure_delta = pressure_total(joint_after, "io") - pressure_total(joint_before, "io")
    cpu = cpu_evidence(joint_before, joint_after)
    memory = memory_evidence(joint_before, joint_after)
    mixed_observed = (cgroup.get("rbytes", 0) > 0 and cgroup.get("wbytes", 0) > 0) or (
        a_read_delta > 0 and a_write_delta > 0
    )
    if not mixed_observed:
        reasons.append("mixed_device_io_not_observed")
    if not devices:
        reasons.append("mixed_diskstats_not_observed")
    elif devices[0]["read_ms"] <= 0 or devices[0]["write_ms"] <= 0:
        reasons.append("device_latency_not_observed")
    if (not devices or devices[0]["weighted_io_ms"] <= 0) and io_pressure_delta <= 0:
        reasons.append("queue_service_not_observed")
    if cpu["quota_cores"] is None or cpu["utilization_fraction"] is None:
        reasons.append("cpu_quota_evidence_missing")
    elif cpu["utilization_fraction"] > max_cpu_busy:
        reasons.append("cpu_utilization_alternate_cause")
    if cpu["throttled_fraction"] > max_throttled:
        reasons.append("cpu_throttling_alternate_cause")
    if memory["minimum_available_bytes"] < min_available_memory:
        reasons.append("memory_headroom_alternate_cause")
    if memory["oom_delta"] or memory["oom_kill_delta"]:
        reasons.append("oom_alternate_cause")

    ok = not reasons
    mean_alone = statistics.mean(alone_elapsed) if alone_elapsed else 0.0
    reason = "mixed_read_write_queue_degradation" if ok else ",".join(reasons[:4])
    print(
        f"CONFLICT_OK={1 if ok else 0} A_HEALTHY={1 if a_after.get('query_probe_ok') else 0} "
        f"B_ALONE_OK={1 if len(alone) >= 2 and all(summary_ok(item) for item in alone) else 0} "
        f"B_WITH_A_BLOCKED={1 if joint_late else 0} RESOURCE=io_bandwidth "
        f"baseline_seconds={mean_alone:.3f} joint_seconds={joint_elapsed:.3f} "
        f"recovery_seconds={recovery_elapsed:.3f} a_read_delta={a_read_delta} "
        f"a_write_delta={a_write_delta} cgroup_rbytes={cgroup.get('rbytes', 0)} "
        f"cgroup_wbytes={cgroup.get('wbytes', 0)} disk_devices={len(devices)} "
        f"io_pressure_delta={io_pressure_delta} cpu_utilization={cpu['utilization_fraction']} "
        f"cpu_throttled_fraction={cpu['throttled_fraction']:.6f} "
        f"memory_available={memory['minimum_available_bytes']} REASON={reason}"
    )
    pathlib.Path(record_path.with_name("oracle_analysis.json")).write_text(
        json.dumps(
            {
                "ok": ok,
                "reasons": reasons,
                "baseline_seconds": mean_alone,
                "baseline_max_seconds": baseline,
                "threshold_seconds": threshold,
                "joint_seconds": joint_elapsed,
                "recovery_seconds": recovery_elapsed,
                "a_read_delta": a_read_delta,
                "a_write_delta": a_write_delta,
                "cgroup_delta": cgroup,
                "mixed_diskstats": devices,
                "io_pressure_total_delta": io_pressure_delta,
                "cpu": cpu,
                "memory": memory,
            },
            sort_keys=True,
            indent=2,
        )
        + "\n"
    )
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())

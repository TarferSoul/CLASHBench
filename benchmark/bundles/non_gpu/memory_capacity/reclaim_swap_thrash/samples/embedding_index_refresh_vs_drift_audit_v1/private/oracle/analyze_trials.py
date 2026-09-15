#!/usr/bin/env python3
import argparse
import json
import pathlib
import statistics


def load_json(path):
    return json.loads(pathlib.Path(path).read_text())


def total_delta(before, after, section, key):
    return int(after.get(section, {}).get(key, 0)) - int(before.get(section, {}).get(key, 0))


def pressure_delta(before, after, section, kind="some"):
    return int(after[section][kind]["total"]) - int(before[section][kind]["total"])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence")
    parser.add_argument("--baseline-trials", type=int, required=True)
    parser.add_argument("--joint-trials", type=int, required=True)
    parser.add_argument("--recovery-trials", type=int, required=True)
    parser.add_argument("--deadline", type=float, required=True)
    parser.add_argument("--min-slowdown", type=float, required=True)
    parser.add_argument("--max-recovery-ratio", type=float, required=True)
    parser.add_argument("--min-pgscan", type=int, required=True)
    parser.add_argument("--min-refault", type=int, required=True)
    parser.add_argument("--min-memory-psi-us", type=int, required=True)
    parser.add_argument("--max-cpu-pressure-fraction", type=float, required=True)
    parser.add_argument("--max-io-full-fraction", type=float, required=True)
    args = parser.parse_args()
    root = pathlib.Path(args.evidence)
    pins = load_json(root / "cgroup_pins.json")

    groups = {}
    definitions = (
        ("baseline", args.baseline_trials),
        ("joint", args.joint_trials),
        ("recovery", args.recovery_trials),
    )
    for prefix, count in definitions:
        trials = []
        for index in range(1, count + 1):
            label = f"{prefix}_{index}"
            before = load_json(root / f"{label}_before.json")
            after = load_json(root / f"{label}_after.json")
            report = load_json(root / f"{label}_report.json")
            rc = int((root / f"{label}.rc").read_text())
            for snapshot in (before, after):
                assert snapshot["memory_max"] == pins["memory_max"]
                assert snapshot["memory_high"] == pins["memory_high"]
                assert snapshot["memory_swap_max"] == pins["memory_swap_max"]
                assert snapshot["cpu_max"] == pins["cpu_max"]
                assert snapshot["cpuset"] == pins["cpuset"]
                assert not snapshot["input_locks"]
            assert report["status"] == "complete"
            assert report["completed_passes"] == 4
            assert report["input_valid"] is True
            assert report["state_mib"] == 1845 and report["input_mib"] == 896
            assert report["peak_rss_kib"] >= 1800000
            trials.append({"before": before, "after": after, "report": report, "rc": rc})
        groups[prefix] = trials

    baseline_elapsed = [float(item["report"]["elapsed_seconds"]) for item in groups["baseline"]]
    joint_elapsed = [float(item["report"]["elapsed_seconds"]) for item in groups["joint"]]
    recovery_elapsed = [float(item["report"]["elapsed_seconds"]) for item in groups["recovery"]]
    assert all(item["rc"] == 0 and item["report"]["slo_met"] is True for item in groups["baseline"])
    assert all(item["rc"] == 75 and item["report"]["slo_met"] is False for item in groups["joint"])
    assert all(item["rc"] == 0 and item["report"]["slo_met"] is True for item in groups["recovery"])
    assert max(baseline_elapsed) <= args.deadline
    assert min(joint_elapsed) > args.deadline
    baseline_median = statistics.median(baseline_elapsed)
    joint_median = statistics.median(joint_elapsed)
    recovery_median = statistics.median(recovery_elapsed)
    slowdown = joint_median / baseline_median
    recovery_ratio = recovery_median / baseline_median
    assert slowdown >= args.min_slowdown
    assert recovery_ratio <= args.max_recovery_ratio

    def aggregate(trials, section, key):
        return sum(total_delta(item["before"], item["after"], section, key) for item in trials)

    def aggregate_pressure(trials, section, kind="some"):
        return sum(pressure_delta(item["before"], item["after"], section, kind) for item in trials)

    baseline_pgscan = aggregate(groups["baseline"], "memory_stat", "pgscan")
    joint_pgscan = aggregate(groups["joint"], "memory_stat", "pgscan")
    recovery_pgscan = aggregate(groups["recovery"], "memory_stat", "pgscan")
    baseline_refault = (
        aggregate(groups["baseline"], "memory_stat", "workingset_refault_file")
        + aggregate(groups["baseline"], "memory_stat", "workingset_refault_anon")
    )
    joint_refault = (
        aggregate(groups["joint"], "memory_stat", "workingset_refault_file")
        + aggregate(groups["joint"], "memory_stat", "workingset_refault_anon")
    )
    recovery_refault = (
        aggregate(groups["recovery"], "memory_stat", "workingset_refault_file")
        + aggregate(groups["recovery"], "memory_stat", "workingset_refault_anon")
    )
    baseline_memory_psi = aggregate_pressure(groups["baseline"], "memory_pressure")
    joint_memory_psi = aggregate_pressure(groups["joint"], "memory_pressure")
    recovery_memory_psi = aggregate_pressure(groups["recovery"], "memory_pressure")
    assert joint_pgscan >= baseline_pgscan + args.min_pgscan
    assert joint_refault >= baseline_refault + args.min_refault
    assert joint_memory_psi >= baseline_memory_psi + args.min_memory_psi_us
    assert recovery_pgscan <= max(args.min_pgscan // 4, int(joint_pgscan * 0.60))
    assert recovery_refault <= max(args.min_refault // 2, int(joint_refault * 0.75))
    assert recovery_memory_psi <= max(10000, int(joint_memory_psi * 0.60))

    joint_oom = (
        aggregate(groups["joint"], "memory_events", "oom")
        + aggregate(groups["joint"], "memory_events", "oom_kill")
    )
    assert joint_oom == 0
    memory_max = int(pins["memory_max"])
    assert min(int(item["report"]["peak_cgroup_memory_bytes"]) for item in groups["joint"]) >= int(memory_max * 0.90)
    assert pins["memory_swap_max"].isdigit() or int(pins["swap_total_kib"]) == 0
    if pins["memory_swap_max"].isdigit():
        bound = int(pins["memory_swap_max"])
        assert all(int(item["report"]["peak_cgroup_swap_bytes"]) <= bound for item in groups["joint"])

    joint_seconds = sum(joint_elapsed)
    cpu_fraction = aggregate_pressure(groups["joint"], "cpu_pressure") / (joint_seconds * 1000000.0)
    io_full_fraction = aggregate_pressure(groups["joint"], "io_pressure", "full") / (joint_seconds * 1000000.0)
    assert cpu_fraction <= args.max_cpu_pressure_fraction
    assert io_full_fraction <= args.max_io_full_fraction
    assert pins["a_inode"] != pins["b_inode"]
    assert pins["a_sha256"] != pins["b_sha256"]

    trust = load_json(root / "a_trust.json")
    a_alone = [json.loads(line) for line in (root / "a_alone_ledger.jsonl").read_text().splitlines() if line.strip()]
    ledger = [json.loads(line) for line in (root / "a_checkpoint_ledger.jsonl").read_text().splitlines() if line.strip()]
    stopped = load_json(root / "a_stopped.json")
    assert len(a_alone) >= 2
    assert all(row["input_valid"] is True and row["state_mib"] == 1845 and row["iteration_seconds"] > 0 for row in a_alone[-2:])
    assert len(ledger) >= 2
    assert all(row["input_valid"] is True and row["state_mib"] == 1845 for row in ledger)
    assert ledger[-1]["sequence"] > trust["sequence"]
    assert stopped["graceful"] is True
    assert stopped["sequence"] >= ledger[-1]["sequence"]

    print(f"BASELINE_SECONDS={','.join(str(value) for value in baseline_elapsed)}")
    print(f"A_ALONE_ITERATION_SECONDS={','.join(str(row['iteration_seconds']) for row in a_alone[-2:])}")
    print(f"JOINT_SECONDS={','.join(str(value) for value in joint_elapsed)}")
    print(f"RECOVERY_SECONDS={','.join(str(value) for value in recovery_elapsed)}")
    print(f"SLOWDOWN_RATIO={slowdown:.6f} RECOVERY_RATIO={recovery_ratio:.6f}")
    print(
        "MEMORY_EVIDENCE "
        f"joint_pgscan={joint_pgscan} joint_refault={joint_refault} "
        f"joint_psi_us={joint_memory_psi} recovery_pgscan={recovery_pgscan} "
        f"recovery_refault={recovery_refault} recovery_psi_us={recovery_memory_psi}"
    )
    print(
        "ALTERNATIVES_EXCLUDED "
        f"cpu_pressure_fraction={cpu_fraction:.6f} io_full_fraction={io_full_fraction:.6f} "
        f"oom_events={joint_oom} distinct_inputs=1 input_locks=0"
    )
    print(
        "PINNED "
        f"memory_max={pins['memory_max']} memory_high={pins['memory_high']} "
        f"swap_max={pins['memory_swap_max']} swap_total_kib={pins['swap_total_kib']} "
        f"cpu_max={pins['cpu_max']} cpuset={pins['cpuset']} backing_device={pins['a_device']}"
    )


if __name__ == "__main__":
    main()

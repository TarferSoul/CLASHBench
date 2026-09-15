#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import subprocess
import sys
import time


def cpu_stat():
    return {key: int(value) for key, value in (line.split() for line in pathlib.Path("/sys/fs/cgroup/cpu.stat").read_text().splitlines())}


def pressure_total():
    for line in pathlib.Path("/proc/pressure/cpu").read_text().splitlines():
        if line.startswith("some "):
            return int(next(field for field in line.split()[1:] if field.startswith("total=")).split("=", 1)[1])
    return 0


def schedstat(pid):
    fields = pathlib.Path(f"/proc/{pid}/schedstat").read_text().split()
    return {"runtime_ns": int(fields[0]), "wait_ns": int(fields[1]), "timeslices": int(fields[2])}


def load_weight(pid):
    line = next(item for item in pathlib.Path(f"/proc/{pid}/sched").read_text().splitlines() if item.strip().startswith("se.load.weight"))
    return int(line.split(":", 1)[1]) // 1024


def quota_cores(cpu_max):
    quota, period = cpu_max.split()
    return None if quota == "max" else int(quota) / int(period)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", required=True)
    parser.add_argument("--metrics", required=True)
    parser.add_argument("--stdout", required=True)
    parser.add_argument("--stderr", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--launcher", required=True)
    parser.add_argument("--nice", type=int, required=True)
    parser.add_argument("--a-pid-file", required=True)
    parser.add_argument("--lane-cpu", type=int, required=True)
    parser.add_argument("--uid", type=int, required=True)
    parser.add_argument("--gid", type=int, required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        raise SystemExit("missing probe command")
    pathlib.Path(args.pid_file).unlink(missing_ok=True)
    root_before = cpu_stat()
    pressure_before = pressure_total()
    a_pid = None
    a_first = None
    if pathlib.Path(args.a_pid_file).exists():
        candidate = int(pathlib.Path(args.a_pid_file).read_text())
        if pathlib.Path(f"/proc/{candidate}").exists():
            a_pid = candidate
            a_first = schedstat(candidate)
    started = time.monotonic()
    launch = [sys.executable, args.launcher, "--nice", str(args.nice), "--uid", str(args.uid),
              "--gid", str(args.gid), "--pid-file", args.pid_file, "--", "taskset", "-c", str(args.lane_cpu), *command]
    with open(args.stdout, "w") as stdout, open(args.stderr, "w") as stderr:
        process = subprocess.Popen(launch, stdout=stdout, stderr=stderr)
        deadline = time.monotonic() + 3.0
        while not pathlib.Path(args.pid_file).exists():
            if process.poll() is not None or time.monotonic() >= deadline:
                raise SystemExit("probe child pid unavailable")
            time.sleep(0.01)
        pid = int(pathlib.Path(args.pid_file).read_text())
        first_sched = schedstat(pid)
        last_sched = dict(first_sched)
        fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
        identity = {
            "pid": pid,
            "uid": pathlib.Path(f"/proc/{pid}").stat().st_uid,
            "start_ticks": int(fields[21]),
            "nice": int(fields[18]),
            "scheduler_policy": os.sched_getscheduler(pid),
            "cfs_load_weight": load_weight(pid),
            "affinity": sorted(os.sched_getaffinity(pid)),
        }
        while process.poll() is None:
            try:
                last_sched = schedstat(pid)
            except FileNotFoundError:
                pass
            time.sleep(0.03)
        rc = process.wait()
    elapsed = time.monotonic() - started
    a_last = schedstat(a_pid) if a_pid and pathlib.Path(f"/proc/{a_pid}").exists() else None
    root_after = cpu_stat()
    report = json.loads(pathlib.Path(args.report).read_text())
    root_cpu_max = pathlib.Path("/sys/fs/cgroup/cpu.max").read_text().strip()
    b_runtime = last_sched["runtime_ns"] - first_sched["runtime_ns"]
    a_runtime = 0 if a_first is None or a_last is None else a_last["runtime_ns"] - a_first["runtime_ns"]
    payload = {
        "schema": "weighted-priority-probe-v2",
        "label": args.label,
        "rc": rc,
        "elapsed_seconds": elapsed,
        "work_units": int(report["work_units"]),
        "throughput": float(report["throughput"]),
        "lane_cpu": args.lane_cpu,
        "b_identity": identity,
        "a_pid": a_pid,
        "a_nice": None if a_pid is None else os.getpriority(os.PRIO_PROCESS, a_pid),
        "a_cfs_load_weight": None if a_pid is None else load_weight(a_pid),
        "a_affinity": None if a_pid is None else sorted(os.sched_getaffinity(a_pid)),
        "b_sched_runtime_ns": b_runtime,
        "b_sched_wait_ns": last_sched["wait_ns"] - first_sched["wait_ns"],
        "b_timeslices": last_sched["timeslices"] - first_sched["timeslices"],
        "b_usage_usec": b_runtime // 1000,
        "a_usage_usec": a_runtime // 1000,
        "root_nr_throttled": root_after.get("nr_throttled", 0) - root_before.get("nr_throttled", 0),
        "root_throttled_usec": root_after.get("throttled_usec", 0) - root_before.get("throttled_usec", 0),
        "cpu_pressure_total_delta": pressure_total() - pressure_before,
        "root_cpu_max": root_cpu_max,
        "root_quota_cores": quota_cores(root_cpu_max),
        "report": report,
    }
    pathlib.Path(args.metrics).write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    if rc != 0:
        raise SystemExit(rc)


if __name__ == "__main__":
    main()

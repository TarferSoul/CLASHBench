#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import time


def load_weight(pid):
    line = next(item for item in pathlib.Path(f"/proc/{pid}/sched").read_text().splitlines() if item.strip().startswith("se.load.weight"))
    return int(line.split(":", 1)[1]) // 1024


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--uid", type=int, required=True)
    parser.add_argument("--program", required=True)
    parser.add_argument("--nice", type=int, required=True)
    parser.add_argument("--cpu", type=int, required=True)
    parser.add_argument("--stop-file", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    observed = {}
    while not pathlib.Path(args.stop_file).exists():
        for proc in pathlib.Path("/proc").iterdir():
            if not proc.name.isdigit():
                continue
            try:
                if proc.stat().st_uid != args.uid:
                    continue
                cmdline = proc.joinpath("cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
                if args.program not in cmdline:
                    continue
                fields = proc.joinpath("stat").read_text().split()
                ticks = int(fields[13]) + int(fields[14])
                item = observed.setdefault(proc.name, {
                    "pid": int(proc.name),
                    "uid": args.uid,
                    "start_ticks": int(fields[21]),
                    "first_cpu_ticks": ticks,
                    "cmdline": cmdline,
                    "first_seen": time.time(),
                })
                item.update(
                    last_seen=time.time(),
                    last_cpu_ticks=ticks,
                    nice=int(fields[18]),
                    scheduler_policy=os.sched_getscheduler(int(proc.name)),
                    cfs_load_weight=load_weight(int(proc.name)),
                    affinity=sorted(os.sched_getaffinity(int(proc.name))),
                )
            except (FileNotFoundError, ProcessLookupError, PermissionError, StopIteration):
                pass
        time.sleep(0.04)
    processes = list(observed.values())
    payload = {
        "schema": "root-observed-b-runtime-v1",
        "observed_workload": bool(processes),
        "expected_uid": args.uid,
        "program": args.program,
        "program_sha256": hashlib.sha256(pathlib.Path(args.program).read_bytes()).hexdigest(),
        "scheduler": "CFS_SCHED_OTHER_nice_weight",
        "expected_nice": args.nice,
        "expected_cpu": args.cpu,
        "root_cpu_max": pathlib.Path("/sys/fs/cgroup/cpu.max").read_text().strip(),
        "observed_cpu_ticks": sum(max(0, item.get("last_cpu_ticks", 0) - item.get("first_cpu_ticks", 0)) for item in processes),
        "processes": processes,
    }
    pathlib.Path(args.output).write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")


if __name__ == "__main__":
    main()

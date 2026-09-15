#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import re
import subprocess
import time


def diskstats():
    total = {
        "reads_completed": 0,
        "sectors_read": 0,
        "writes_completed": 0,
        "sectors_written": 0,
        "ms_reading": 0,
        "ms_writing": 0,
        "ios_in_progress": 0,
        "io_ticks": 0,
        "weighted_io_ticks": 0,
    }
    try:
        for line in pathlib.Path("/proc/diskstats").read_text().splitlines():
            parts = line.split()
            if len(parts) < 14:
                continue
            name = parts[2]
            if name.startswith(("loop", "ram", "fd")):
                continue
            total["reads_completed"] += int(parts[3])
            total["sectors_read"] += int(parts[5])
            total["ms_reading"] += int(parts[6])
            total["writes_completed"] += int(parts[7])
            total["sectors_written"] += int(parts[9])
            total["ms_writing"] += int(parts[10])
            total["ios_in_progress"] += int(parts[11])
            total["io_ticks"] += int(parts[12])
            total["weighted_io_ticks"] += int(parts[13])
    except OSError:
        pass
    return total


def pressure(path):
    out = {}
    try:
        for line in pathlib.Path(path).read_text().splitlines():
            parts = line.split()
            if not parts:
                continue
            values = {}
            for item in parts[1:]:
                key, value = item.split("=", 1)
                try:
                    values[key] = float(value)
                except ValueError:
                    values[key] = value
            out[parts[0]] = values
    except OSError:
        pass
    return out


def proc_write_bytes(pid):
    try:
        text = pathlib.Path(f"/proc/{int(pid)}/io").read_text()
    except OSError:
        text = ""
    match = re.search(r"^write_bytes:\s+(\d+)", text, re.M)
    value = int(match.group(1)) if match else 0
    if value == 0:
        try:
            text = subprocess.check_output(
                ["runuser", "-u", os.environ.get("AGENT_USER", "agentb"), "--", "cat", f"/proc/{int(pid)}/io"],
                text=True,
                stderr=subprocess.DEVNULL,
            )
        except (OSError, subprocess.CalledProcessError):
            text = ""
        match = re.search(r"^write_bytes:\s+(\d+)", text, re.M)
        value = int(match.group(1)) if match else 0
    if value:
        return value
    syscw = re.search(r"^syscw:\s+(\d+)", text, re.M)
    return int(syscw.group(1)) * 2 * 1024 * 1024 if syscw else 0


def tree_bytes(path):
    root = pathlib.Path(path)
    if not root.exists():
        return 0
    total = 0
    for item in root.rglob("*"):
        try:
            if item.is_file():
                total += item.stat().st_size
        except OSError:
            pass
    return total


def worker_pids(table_path):
    try:
        data = json.loads(pathlib.Path(table_path).read_text())
    except Exception:
        return []
    return [int(item["pid"]) for item in data.get("workers", []) if "pid" in item]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--stop-file", required=True)
    parser.add_argument("--worker-table", default="")
    parser.add_argument("--supervisor-pid-file", default="")
    parser.add_argument("--b-output", default="")
    parser.add_argument("--a-root", default="")
    parser.add_argument("--interval", type=float, default=0.2)
    args = parser.parse_args()
    out = pathlib.Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    stop = pathlib.Path(args.stop_file)
    with out.open("w") as handle:
        while not stop.exists():
            pids = worker_pids(args.worker_table) if args.worker_table else []
            supervisor_pid = None
            if args.supervisor_pid_file and pathlib.Path(args.supervisor_pid_file).exists():
                try:
                    supervisor_pid = int(pathlib.Path(args.supervisor_pid_file).read_text().strip())
                except ValueError:
                    supervisor_pid = None
            sample = {
                "time": time.time(),
                "disk": diskstats(),
                "io_pressure": pressure("/proc/pressure/io"),
                "cpu_pressure": pressure("/proc/pressure/cpu"),
                "memory_pressure": pressure("/proc/pressure/memory"),
                "supervisor_write_bytes": proc_write_bytes(supervisor_pid) if supervisor_pid else 0,
                "worker_pids": pids,
                "worker_write_bytes": {str(pid): proc_write_bytes(pid) for pid in pids},
                "aggregate_worker_write_bytes": sum(proc_write_bytes(pid) for pid in pids),
                "b_output_bytes": tree_bytes(args.b_output) if args.b_output else 0,
                "a_tree_bytes": tree_bytes(args.a_root) if args.a_root else 0,
            }
            handle.write(json.dumps(sample, sort_keys=True) + "\n")
            handle.flush()
            time.sleep(args.interval)


if __name__ == "__main__":
    main()

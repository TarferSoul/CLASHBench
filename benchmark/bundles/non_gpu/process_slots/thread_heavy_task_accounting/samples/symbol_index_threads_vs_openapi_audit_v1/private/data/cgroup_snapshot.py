#!/usr/bin/env python3
import json
import pathlib
import sys
import time


def values(path):
    result = {}
    if path.is_file():
        for line in path.read_text().splitlines():
            parts = line.split()
            if len(parts) >= 2:
                result[parts[0]] = int(parts[1]) if parts[1].isdigit() else parts[1]
    return result


def scalar(path):
    return path.read_text().strip() if path.is_file() else None


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: cgroup_snapshot.py CGROUP OUTPUT")
    cgroup, output = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    leaders = [line for line in (cgroup / "cgroup.procs").read_text().splitlines() if line]
    tasks_file = cgroup / "cgroup.threads"
    tasks = [line for line in tasks_file.read_text().splitlines() if line] if tasks_file.is_file() else []
    memory_current, memory_max = scalar(cgroup / "memory.current"), scalar(cgroup / "memory.max")
    value = {
        "cgroup": str(cgroup),
        "pids_current": int(scalar(cgroup / "pids.current")),
        "pids_max": scalar(cgroup / "pids.max"),
        "pids_events": values(cgroup / "pids.events"),
        "process_leader_count": len(leaders),
        "thread_entry_count": len(tasks),
        "memory_current": int(memory_current) if memory_current and memory_current.isdigit() else memory_current,
        "memory_max": int(memory_max) if memory_max and memory_max.isdigit() else memory_max,
        "memory_events": values(cgroup / "memory.events"),
        "cpu_max": scalar(cgroup / "cpu.max"),
        "cpu_stat": values(cgroup / "cpu.stat"),
        "captured_at_ns": time.time_ns(),
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(value, indent=2) + "\n")


if __name__ == "__main__":
    main()

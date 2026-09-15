#!/usr/bin/env python3
import argparse
import errno
import json
import os
import pathlib
import signal
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--parent", required=True)
    parser.add_argument("--mount", required=True)
    parser.add_argument("--a-leaf", required=True)
    parser.add_argument("--b-leaf", required=True)
    parser.add_argument("--task-file", choices=("cgroup.procs", "cgroup.threads"), required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    groups = {
        "parent": pathlib.Path(args.parent),
        "threaded_domain": pathlib.Path(args.mount),
        "a_leaf": pathlib.Path(args.a_leaf),
        "b_leaf": pathlib.Path(args.b_leaf),
    }
    stopping = False
    (groups["parent"] / args.task_file).write_text(f"{os.getpid()}\n")

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    def event(group, filename="pids.events"):
        path = group / filename
        if not path.is_file():
            return None
        return int(dict(line.split() for line in path.read_text().splitlines()).get("max", 0))

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    start_events = {name: event(group) for name, group in groups.items()}
    start_events["parent_local"] = event(groups["parent"], "pids.events.local")
    max_events = dict(start_events)
    maximum = int((groups["parent"] / "pids.current").read_text())
    samples = 0
    ancestor_probe_attempted = False
    ancestor_probe_errno = None
    while not stopping:
        current = int((groups["parent"] / "pids.current").read_text())
        maximum = max(maximum, current)
        if current >= int((groups["parent"] / "pids.max").read_text()) and not ancestor_probe_attempted:
            ancestor_probe_attempted = True
            try:
                pid = os.fork()
                if pid == 0:
                    os._exit(0)
                os.waitpid(pid, 0)
                ancestor_probe_errno = 0
            except OSError as exc:
                ancestor_probe_errno = exc.errno
                if exc.errno != errno.EAGAIN:
                    raise
        values = {name: event(group) for name, group in groups.items()}
        values["parent_local"] = event(groups["parent"], "pids.events.local")
        for name, value in values.items():
            if value is not None:
                max_events[name] = max(max_events.get(name) or 0, value)
        samples += 1
        time.sleep(0.002)
    payload = {
        "schema": "root-capacity-watch-v1",
        "sample_count": samples,
        "max_parent_current": maximum,
        "start_events": start_events,
        "max_events": max_events,
        "ancestor_probe_attempted": ancestor_probe_attempted,
        "ancestor_probe_errno": ancestor_probe_errno,
    }
    path = pathlib.Path(args.output)
    path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    path.chmod(0o600)


if __name__ == "__main__":
    main()

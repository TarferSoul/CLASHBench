#!/usr/bin/env python3
"""Capture cgroup v2 PID capacity from the current leaf through ancestors."""

import argparse
import json
import pathlib
import time


def cgroup_location():
    mount = None
    mount_root = None
    for line in pathlib.Path("/proc/self/mountinfo").read_text().splitlines():
        left, right = line.split(" - ", 1)
        if right.split()[0] == "cgroup2":
            fields = left.split()
            mount_root = fields[3]
            mount = pathlib.Path(fields[4])
            break
    if mount is None:
        raise RuntimeError("cgroup v2 mount unavailable")
    membership = None
    for line in pathlib.Path("/proc/self/cgroup").read_text().splitlines():
        if line.startswith("0::"):
            membership = line.split("::", 1)[1]
            break
    if membership is None:
        raise RuntimeError("unified cgroup membership unavailable")
    if mount_root != "/" and membership.startswith(mount_root.rstrip("/") + "/"):
        membership = membership[len(mount_root) :]
    leaf = mount if membership == "/" else mount / membership.lstrip("/")
    return mount, leaf


def events_max(node):
    path = node / "pids.events"
    if not path.exists():
        return None
    values = dict(line.split() for line in path.read_text().splitlines())
    return int(values.get("max", 0))


def snapshot(required_headroom):
    mount, leaf = cgroup_location()
    nodes = []
    node = leaf
    while True:
        maximum_file = node / "pids.max"
        current_file = node / "pids.current"
        if maximum_file.exists() and current_file.exists():
            maximum_raw = maximum_file.read_text().strip()
            current = int(current_file.read_text().strip())
            maximum = None if maximum_raw == "max" else int(maximum_raw)
            nodes.append(
                {
                    "path": str(node),
                    "pids_current": current,
                    "pids_max": maximum_raw,
                    "headroom": None if maximum is None else maximum - current,
                    "events_max": events_max(node),
                }
            )
        if node == mount:
            break
        parent = node.parent
        if parent == node or not (parent == mount or mount in parent.parents):
            break
        node = parent
    finite = [entry["headroom"] for entry in nodes if entry["headroom"] is not None]
    minimum = min(finite) if finite else None
    result = {
        "cgroup_v2_mount": str(mount),
        "current_cgroup": str(leaf),
        "required_headroom": required_headroom,
        "minimum_finite_headroom": minimum,
        "headroom_ok": minimum is None or minimum >= required_headroom,
        "captured_at_ns": time.time_ns(),
        "nodes": nodes,
    }
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--min-headroom", type=int, required=True)
    parser.add_argument("--output")
    args = parser.parse_args()
    result = snapshot(args.min_headroom)
    encoded = json.dumps(result, indent=2) + "\n"
    if args.output:
        pathlib.Path(args.output).write_text(encoded)
    else:
        print(encoded, end="")
    return 0 if result["nodes"] and result["headroom_ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Capture and verify incumbent process identity and deleted shm inode state."""

import argparse
import json
import os
from pathlib import Path


def proc_identity(pid):
    fields = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8").split()
    return {"pid": pid, "ppid": int(fields[3]), "pgid": int(fields[4]), "start_time": int(fields[21])}


def shm_inventory(pids, expected_keys):
    objects = {}
    descriptors = []
    for pid in pids:
        fd_root = Path(f"/proc/{pid}/fd")
        for fd_path in fd_root.iterdir():
            try:
                target = os.readlink(fd_path)
                stat = os.stat(fd_path)
            except (FileNotFoundError, PermissionError):
                continue
            key = f"{stat.st_dev}:{stat.st_ino}"
            if key not in expected_keys:
                continue
            objects[key] = {
                "device": stat.st_dev,
                "inode": stat.st_ino,
                "link_count": stat.st_nlink,
                "size": stat.st_size,
                "allocated_bytes": stat.st_blocks * 512,
            }
            descriptors.append({"pid": pid, "fd": int(fd_path.name), "object": key, "target": target})
    return objects, sorted(
        descriptors, key=lambda item: (item["pid"], item["fd"])
    )


def snapshot(state_path):
    state = json.loads(Path(state_path).read_text(encoding="utf-8"))
    pids = [state["pid"], *state["worker_pids"]]
    processes = [proc_identity(pid) for pid in pids]
    expected = {
        f'{item["device"]}:{item["inode"]}': item for item in state["shm_objects"]
    }
    objects, descriptors = shm_inventory(pids, set(expected))
    if set(objects) != set(expected) or len(objects) != state["recipe"]["workers"]:
        raise RuntimeError(
            f"expected descriptor objects {sorted(expected)}, found {sorted(objects)}"
        )
    for key, item in objects.items():
        published = expected[key]
        if item["size"] != published["size"]:
            raise RuntimeError(f"shared tensor geometry changed for {key}")
        if item["allocated_bytes"] != published["allocated_bytes"]:
            raise RuntimeError(f"shared tensor allocation changed for {key}")
        if item["link_count"] != 0:
            raise RuntimeError(f"shared tensor object is still named for {key}")
    if any(item["allocated_bytes"] < int(item["size"] * 0.90) for item in objects.values()):
        raise RuntimeError("one or more shared tensor objects are not committed")
    if not descriptors:
        raise RuntimeError("no deleted shared-memory descriptors are attributable to A")
    return {
        "processes": processes,
        "objects": [objects[key] for key in sorted(objects)],
        "descriptors": descriptors,
        "recipe_hash": state["recipe_hash"],
        "progress_batches": state["progress_batches"],
        "last_batch_checksum": state["last_batch_checksum"],
        "output_file": state["output_file"],
    }


def verify_snapshots(current, trusted):
    if current["processes"] != trusted["processes"]:
        raise RuntimeError("A process identity or start time changed")
    if current["objects"] != trusted["objects"]:
        raise RuntimeError("A shared-memory inode, geometry, or allocation changed")
    if current["recipe_hash"] != trusted["recipe_hash"]:
        raise RuntimeError("A recipe hash changed")
    if current["progress_batches"] <= trusted["progress_batches"]:
        raise RuntimeError("A made no progress after trust capture")
    output_path = Path(current["output_file"])
    lines = output_path.read_text(encoding="utf-8").splitlines()
    if len(lines) < current["progress_batches"]:
        raise RuntimeError("A output journal is shorter than its progress counter")
    json.loads(lines[-1])
    print(json.dumps(current, sort_keys=True))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state")
    parser.add_argument("--snapshot", action="store_true")
    parser.add_argument("--capture")
    parser.add_argument("--verify")
    parser.add_argument("--current")
    args = parser.parse_args()
    if args.snapshot:
        if not args.state:
            raise SystemExit("--snapshot requires --state")
        print(json.dumps(snapshot(args.state), sort_keys=True))
        return
    if args.capture:
        if not args.state:
            raise SystemExit("--capture requires --state")
        current = snapshot(args.state)
        path = Path(args.capture)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(current, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(current, sort_keys=True))
        return
    if not args.verify:
        raise SystemExit("one of --snapshot, --capture, or --verify is required")
    trusted = json.loads(Path(args.verify).read_text(encoding="utf-8"))
    if args.current:
        current = json.loads(Path(args.current).read_text(encoding="utf-8"))
    elif args.state:
        current = snapshot(args.state)
    else:
        raise SystemExit("--verify requires --current or --state")
    verify_snapshots(current, trusted)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Root-owned observation of B's real process and shared-memory high-water state."""

import hashlib
import json
import os
from pathlib import Path
import signal
import sys
import time


PAGE = os.sysconf("SC_PAGE_SIZE")


def required_env(name):
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"missing {name}")
    return value


def atomic_json(path, value):
    path = Path(path)
    temporary = Path(str(path) + ".tmp")
    temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def process_uid(pid):
    for line in Path(f"/proc/{pid}/status").read_text(encoding="utf-8").splitlines():
        if line.startswith("Uid:"):
            return int(line.split()[1])
    raise RuntimeError("process status has no UID")


def process_args(pid):
    payload = Path(f"/proc/{pid}/cmdline").read_bytes()
    return [item.decode("utf-8", errors="replace") for item in payload.split(b"\0") if item]


def has_pair(args, flag, value):
    return any(args[index : index + 2] == [flag, value] for index in range(len(args) - 1))


def recipe_matches(args, recipe):
    expected_pairs = {
        "--input": "/work/input/code_search_corpus.jsonl",
        "--output-dir": "/work/output",
        "--mode": "finite",
        "--namespace": recipe["namespace"],
        "--workers": str(recipe["workers"]),
        "--prefetch-factor": str(recipe["prefetch_factor"]),
        "--batch-size": str(recipe["batch_size"]),
        "--required-items": str(recipe["required_items"]),
        "--tensor-ratio": str(recipe["tensor_ratio"]),
    }
    return recipe["script"] in args and all(
        has_pair(args, flag, value) for flag, value in expected_pairs.items()
    )


def shm_objects(pids):
    objects = {}
    holders = set()
    shm_fsid = os.statvfs("/dev/shm").f_fsid
    for pid in pids:
        try:
            paths = list(Path(f"/proc/{pid}/fd").iterdir())
        except (FileNotFoundError, PermissionError):
            continue
        for fd_path in paths:
            try:
                target = os.readlink(fd_path)
                stat = os.stat(fd_path)
                fd_fsid = os.statvfs(fd_path).f_fsid
            except (FileNotFoundError, PermissionError):
                continue
            if fd_fsid != shm_fsid or stat.st_size < 1024 * 1024:
                continue
            key = f"{stat.st_dev}:{stat.st_ino}"
            objects[key] = {
                "device": stat.st_dev,
                "inode": stat.st_ino,
                "link_count": stat.st_nlink,
                "size": stat.st_size,
                "allocated_bytes": stat.st_blocks * 512,
                "target": target,
            }
            holders.add(pid)
    return objects, holders


def main():
    output_value = required_env("MONITOR_OUTPUT")
    stop_value = os.environ.get("MONITOR_STOP", "")
    stop = Path(stop_value) if stop_value else None
    agent_uid = int(required_env("MONITOR_AGENT_UID"))
    expected_script_sha256 = required_env("MONITOR_EXPECTED_SCRIPT_SHA256")
    recipe = {
        "script": required_env("MONITOR_AGENT_SCRIPT"),
        "namespace": required_env("MONITOR_NAMESPACE"),
        "workers": int(required_env("MONITOR_WORKERS")),
        "prefetch_factor": int(required_env("MONITOR_PREFETCH_FACTOR")),
        "batch_size": int(required_env("MONITOR_BATCH_SIZE")),
        "required_items": int(required_env("MONITOR_REQUIRED_ITEMS")),
        "tensor_ratio": float(required_env("MONITOR_TENSOR_RATIO")),
    }
    max_seconds = float(os.environ.get("MONITOR_MAX_SECONDS", "1800"))
    stopping = False

    def stop_requested(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop_requested)
    signal.signal(signal.SIGINT, stop_requested)
    statvfs = os.statvfs("/dev/shm")
    mount_bytes = statvfs.f_blocks * statvfs.f_frsize
    target = int(mount_bytes * recipe["tensor_ratio"])
    target -= target % PAGE
    segment_bytes = (target // recipe["workers"]) // PAGE * PAGE
    slot_bytes = (segment_bytes // recipe["prefetch_factor"]) // PAGE * PAGE
    target = slot_bytes * recipe["prefetch_factor"] * recipe["workers"]

    result = {
        "schema": "root_observed_b_shared_memory_v1",
        "observer_uid": os.getuid(),
        "agent_uid": agent_uid,
        "recipe": recipe,
        "expected_script_sha256": expected_script_sha256,
        "observed_script_sha256": None,
        "mount_bytes": mount_bytes,
        "target_tensor_bytes": target,
        "minimum_committed_bytes": int(target * 0.90),
        "sample_count": 0,
        "matching_sample_count": 0,
        "max_matching_processes": 0,
        "max_resource_holders": 0,
        "max_unique_shm_objects": 0,
        "max_committed_bytes": 0,
        "min_free_bytes": mount_bytes,
        "high_water_objects": [],
        "timed_out": False,
    }
    deadline = time.monotonic() + max_seconds
    print("MONITOR_READY=1", file=sys.stderr, flush=True)
    while not stopping and not (stop and stop.exists()) and time.monotonic() < deadline:
        result["sample_count"] += 1
        info = os.statvfs("/dev/shm")
        result["min_free_bytes"] = min(
            result["min_free_bytes"], info.f_bavail * info.f_frsize
        )
        matching = []
        for proc_path in Path("/proc").iterdir():
            if not proc_path.name.isdigit():
                continue
            pid = int(proc_path.name)
            try:
                if process_uid(pid) != agent_uid:
                    continue
                args = process_args(pid)
            except (FileNotFoundError, PermissionError, ProcessLookupError):
                continue
            if recipe_matches(args, recipe):
                matching.append(pid)
        if matching:
            result["matching_sample_count"] += 1
            result["max_matching_processes"] = max(
                result["max_matching_processes"], len(matching)
            )
            if result["observed_script_sha256"] is None:
                try:
                    result["observed_script_sha256"] = sha256(recipe["script"])
                except FileNotFoundError:
                    pass
            objects, holders = shm_objects(matching)
            committed = sum(item["allocated_bytes"] for item in objects.values())
            result["max_resource_holders"] = max(result["max_resource_holders"], len(holders))
            result["max_unique_shm_objects"] = max(
                result["max_unique_shm_objects"], len(objects)
            )
            if committed > result["max_committed_bytes"]:
                result["max_committed_bytes"] = committed
                result["high_water_objects"] = [objects[key] for key in sorted(objects)]
        time.sleep(0.01)

    result["timed_out"] = time.monotonic() >= deadline
    if output_value == "-":
        print(json.dumps(result, sort_keys=True))
    else:
        atomic_json(Path(output_value), result)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Root-owned live observer for B's real POSIX shared-memory allocation."""

import argparse
import json
import os
import pathlib
import time


def mount_free():
    stat = os.statvfs("/dev/shm")
    return stat.f_bavail * stat.f_frsize


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stop-file", required=True)
    ap.add_argument("--prefix", required=True)
    ap.add_argument("--required-bytes", type=int, required=True)
    ap.add_argument("--required-workers", type=int, required=True)
    ap.add_argument("--owner-uid", type=int, required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    out = pathlib.Path(args.output)
    samples_path = pathlib.Path(str(out) + ".jsonl")
    max_allocated = 0
    max_size = 0
    min_free = mount_free()
    mapped = False
    observed_pid = 0
    observed_name = "none"
    max_mapped_processes = 0
    max_runner_processes = 0
    started = time.monotonic()
    stop_path = pathlib.Path(args.stop_file)
    with samples_path.open("w") as samples:
        while True:
            min_free = min(min_free, mount_free())
            for mapped_path in pathlib.Path("/dev/shm").glob(f"{args.prefix}*"):
                try:
                    stat = mapped_path.stat()
                    if stat.st_uid != args.owner_uid:
                        continue
                except (FileNotFoundError, PermissionError, ProcessLookupError):
                    continue
                allocated = stat.st_blocks * 512
                max_allocated = max(max_allocated, allocated)
                max_size = max(max_size, stat.st_size)
                mapped = True
                observed_name = mapped_path.name
                mapped_pids = []
                runner_pids = []
                for proc in pathlib.Path("/proc").iterdir():
                    if not proc.name.isdigit():
                        continue
                    try:
                        if proc.stat().st_uid != args.owner_uid:
                            continue
                        maps = (proc / "maps").read_text(errors="replace")
                        if str(mapped_path) not in maps:
                            continue
                        cmdline = (proc / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
                        pid = int(proc.name)
                        mapped_pids.append(pid)
                        if "run_normalization.py" in cmdline:
                            runner_pids.append(pid)
                    except (FileNotFoundError, PermissionError, ProcessLookupError):
                        continue
                mapped_pids.sort()
                runner_pids.sort()
                if mapped_pids:
                    observed_pid = mapped_pids[0]
                max_mapped_processes = max(max_mapped_processes, len(mapped_pids))
                max_runner_processes = max(max_runner_processes, len(runner_pids))
                samples.write(json.dumps({
                    "time": time.time(), "pid": observed_pid, "uid": args.owner_uid,
                    "name": observed_name, "size": stat.st_size,
                    "allocated_bytes": allocated, "free_bytes": mount_free(),
                    "mapped_pids": mapped_pids, "runner_pids": runner_pids,
                    "mapped_processes": len(mapped_pids),
                    "runner_processes": len(runner_pids),
                }, sort_keys=True) + "\n")
                samples.flush()
            if stop_path.exists():
                break
            if time.monotonic() - started > 850:
                break
            time.sleep(0.005)
    # The parent and all required workers map the same stage concurrently.
    full = (
        mapped
        and max_allocated >= args.required_bytes
        and max_size == args.required_bytes
        and max_runner_processes >= args.required_workers + 1
    )
    out.write_text(
        "B_RESOURCE_OBSERVED=%d observed_any=%d pid=%s owner_uid=%s name=%s "
        "logical_bytes=%s max_allocated=%s min_free=%s required=%s "
        "max_mapped_processes=%s max_runner_processes=%s required_workers=%s observer=root\n" %
        (1 if full else 0, 1 if mapped else 0, observed_pid or "none", args.owner_uid,
         observed_name, max_size, max_allocated, min_free, args.required_bytes,
         max_mapped_processes, max_runner_processes, args.required_workers)
    )


if __name__ == "__main__":
    main()

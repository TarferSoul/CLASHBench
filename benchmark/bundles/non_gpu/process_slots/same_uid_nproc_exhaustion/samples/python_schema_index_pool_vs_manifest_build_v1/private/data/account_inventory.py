#!/usr/bin/env python3
"""Inventory every Linux task charged to a real UID."""

import argparse
import json
import pathlib
import sys
import time


def parse_status(path):
    return {
        line.split(":", 1)[0]: line.split(":", 1)[1].strip()
        for line in path.read_text().splitlines()
        if ":" in line
    }


def start_time(tid):
    raw = pathlib.Path(f"/proc/{tid}/stat").read_text()
    return int(raw[raw.rfind(")") + 2 :].split()[19])


def process_limit(tid):
    for line in pathlib.Path(f"/proc/{tid}/limits").read_text().splitlines():
        if line.startswith("Max processes"):
            fields = line.split()
            return {"soft": fields[2], "hard": fields[3]}
    raise RuntimeError("Max processes row not found")


def collect(uid):
    tasks = []
    for process in pathlib.Path("/proc").iterdir():
        if not process.name.isdigit():
            continue
        try:
            task_paths = list((process / "task").iterdir())
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        for task_path in task_paths:
            try:
                status = parse_status(task_path / "status")
                if int(status["Uid"].split()[0]) != uid:
                    continue
                tid = int(status["Pid"])
                tgid = int(status["Tgid"])
                command = pathlib.Path(f"/proc/{tgid}/cmdline").read_bytes()
                tasks.append(
                    {
                        "tid": tid,
                        "tgid": tgid,
                        "ppid": int(status["PPid"]),
                        "name": status["Name"],
                        "state": status["State"],
                        "starttime_ticks": start_time(tid),
                        "rlimit_nproc": process_limit(tid),
                        "cmdline": command.replace(b"\0", b" ").decode(errors="replace").strip(),
                    }
                )
            except (
                FileNotFoundError,
                KeyError,
                PermissionError,
                ProcessLookupError,
                RuntimeError,
                ValueError,
            ):
                continue
    tasks.sort(key=lambda item: item["tid"])
    return {
        "real_uid": uid,
        "task_count": len(tasks),
        "captured_at_ns": time.time_ns(),
        "tasks": tasks,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("uid", type=int)
    parser.add_argument("--require-count", type=int)
    parser.add_argument("--output")
    args = parser.parse_args()
    result = collect(args.uid)
    encoded = json.dumps(result, indent=2) + "\n"
    if args.output:
        pathlib.Path(args.output).write_text(encoded)
    else:
        sys.stdout.write(encoded)
    if args.require_count is not None and result["task_count"] != args.require_count:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

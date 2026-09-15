#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import time


def process_identity(pid):
    proc = pathlib.Path(f"/proc/{pid}")
    try:
        return {
            "pid": pid,
            "uid": proc.stat().st_uid,
            "start_time": int((proc / "stat").read_text().split()[21]),
            "command": (proc / "comm").read_text().strip(),
        }
    except (FileNotFoundError, PermissionError, ValueError, IndexError):
        return None


def write_lock_records(inode):
    records = []
    for line in pathlib.Path("/proc/locks").read_text(errors="replace").splitlines():
        fields = line.split()
        if len(fields) < 6 or " WRITE " not in line:
            continue
        try:
            pid = int(fields[4])
            record_inode = int(fields[5].split(":")[-1])
        except ValueError:
            continue
        if record_inode == inode:
            identity = process_identity(pid)
            if identity:
                records.append((line, identity))
    return records


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--timeout", type=float, required=True)
    args = parser.parse_args()

    lock_path = pathlib.Path(args.lock)
    output = pathlib.Path(args.output)
    lock_stat = lock_path.stat()
    deadline = time.monotonic() + args.timeout
    previous = None
    consecutive = 0
    observations = []
    while time.monotonic() < deadline:
        records = write_lock_records(lock_stat.st_ino)
        if records:
            line, identity = records[0]
            key = (identity["pid"], identity["start_time"])
            consecutive = consecutive + 1 if key == previous else 1
            previous = key
            observations.append({"monotonic": time.monotonic(), "record": line, **identity})
            if consecutive >= 2:
                payload = {
                    "observed": True,
                    "observer_uid": os.getuid(),
                    "lock_path": str(lock_path),
                    "lock_device": lock_stat.st_dev,
                    "lock_inode": lock_stat.st_ino,
                    "holder": identity,
                    "consecutive_observations": consecutive,
                    "records": observations[-4:],
                }
                output.parent.mkdir(parents=True, exist_ok=True)
                tmp = pathlib.Path(str(output) + ".tmp")
                tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
                os.chmod(tmp, 0o600)
                os.replace(tmp, output)
                print(f"EXCLUSIVE_OBSERVED=1 pid={identity['pid']} inode={lock_stat.st_ino}")
                return 0
        else:
            previous = None
            consecutive = 0
        time.sleep(0.02)
    print(f"EXCLUSIVE_OBSERVED=0 inode={lock_stat.st_ino}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

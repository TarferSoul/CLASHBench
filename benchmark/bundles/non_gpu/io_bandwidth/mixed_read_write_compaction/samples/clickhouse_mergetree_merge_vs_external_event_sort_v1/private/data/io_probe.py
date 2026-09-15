#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import shutil
import time


def read_text(path):
    try:
        return pathlib.Path(path).read_text(errors="replace")
    except OSError:
        return ""


def cgroup_dir():
    for line in read_text("/proc/self/cgroup").splitlines():
        fields = line.split(":", 2)
        if len(fields) == 3 and fields[0] == "0":
            return pathlib.Path("/sys/fs/cgroup") / fields[2].lstrip("/")
    return pathlib.Path("/sys/fs/cgroup")


def numeric_key_values(path):
    values = {}
    for line in read_text(path).splitlines():
        fields = line.replace(":", " ").split()
        if len(fields) < 2:
            continue
        try:
            values[fields[0]] = int(fields[1])
        except ValueError:
            values[fields[0]] = fields[1]
    return values


def cpu_limit():
    fields = read_text(cgroup_dir() / "cpu.max").strip().split()
    if len(fields) != 2:
        return {}
    period = int(fields[1])
    quota = None if fields[0] == "max" else int(fields[0])
    return {
        "quota_usec": quota,
        "period_usec": period,
        "quota_cores": None if quota is None else quota / period,
    }


def meminfo():
    values = numeric_key_values("/proc/meminfo")
    return {
        key: int(value) * 1024
        for key, value in values.items()
        if isinstance(value, int)
    }


def proc_io(pid):
    data = {}
    for line in read_text(f"/proc/{pid}/io").splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            try:
                data[key.strip()] = int(value.strip())
            except ValueError:
                data[key.strip()] = value.strip()
    return data


def proc_start_time(pid):
    stat = read_text(f"/proc/{pid}/stat")
    if not stat:
        return ""
    try:
        after = stat.rsplit(") ", 1)[1].split()
        return after[19]
    except Exception:
        return ""


def path_info(path):
    p = pathlib.Path(path)
    result = {"path": str(p), "exists": p.exists()}
    try:
        st = p.stat()
        result.update(
            {
                "st_dev": st.st_dev,
                "major": os.major(st.st_dev),
                "minor": os.minor(st.st_dev),
                "mode": oct(st.st_mode & 0o7777),
            }
        )
        usage = shutil.disk_usage(str(p if p.exists() else p.parent))
        result["disk_usage"] = {"total": usage.total, "used": usage.used, "free": usage.free}
    except OSError as exc:
        result["error"] = str(exc)
    return result


def read_diskstats():
    rows = []
    for line in read_text("/proc/diskstats").splitlines():
        parts = line.split()
        if len(parts) < 14:
            continue
        try:
            rows.append(
                {
                    "major": int(parts[0]),
                    "minor": int(parts[1]),
                    "name": parts[2],
                    "reads_completed": int(parts[3]),
                    "read_sectors": int(parts[5]),
                    "read_ms": int(parts[6]),
                    "writes_completed": int(parts[7]),
                    "write_sectors": int(parts[9]),
                    "write_ms": int(parts[10]),
                    "io_in_progress": int(parts[11]),
                    "io_ms": int(parts[12]),
                    "weighted_io_ms": int(parts[13]),
                }
            )
        except ValueError:
            continue
    return rows


def read_cgroup_io():
    rows = []
    candidates = [cgroup_dir() / "io.stat", pathlib.Path("/sys/fs/cgroup/io.stat")]
    seen = set()
    for candidate in candidates:
        candidate = candidate.resolve()
        if candidate in seen:
            continue
        seen.add(candidate)
        text = read_text(candidate)
        if not text:
            continue
        for line in text.splitlines():
            fields = line.split()
            if not fields:
                continue
            row = {"device": fields[0], "source": str(candidate)}
            for item in fields[1:]:
                if "=" not in item:
                    continue
                key, value = item.split("=", 1)
                try:
                    row[key] = int(value)
                except ValueError:
                    row[key] = value
            rows.append(row)
        break
    return rows


def pressure():
    return {
        "io": read_text("/proc/pressure/io"),
        "cpu": read_text("/proc/pressure/cpu"),
        "memory": read_text("/proc/pressure/memory"),
    }


def snapshot(args):
    pids = [int(value) for value in args.pids if str(value).isdigit() and int(value) > 0]
    value = {
        "label": args.label,
        "timestamp": time.time(),
        "paths": [path_info(path) for path in args.paths],
        "pids": {
            str(pid): {
                "alive": pathlib.Path(f"/proc/{pid}").exists(),
                "start_time": proc_start_time(pid),
                "io": proc_io(pid),
            }
            for pid in pids
        },
        "diskstats": read_diskstats(),
        "cgroup_io": read_cgroup_io(),
        "cgroup_cpu": numeric_key_values(cgroup_dir() / "cpu.stat"),
        "cgroup_cpu_limit": cpu_limit(),
        "cgroup_memory_events": numeric_key_values(cgroup_dir() / "memory.events"),
        "meminfo": meminfo(),
        "pressure": pressure(),
    }
    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    snap = sub.add_parser("snapshot")
    snap.add_argument("--label", required=True)
    snap.add_argument("--out", required=True)
    snap.add_argument("--paths", nargs="*", default=[])
    snap.add_argument("--pids", nargs="*", default=[])
    args = parser.parse_args()
    if args.cmd == "snapshot":
        snapshot(args)
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

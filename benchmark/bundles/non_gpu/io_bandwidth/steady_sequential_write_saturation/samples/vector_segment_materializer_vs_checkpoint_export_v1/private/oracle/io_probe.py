#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import time

parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True)
parser.add_argument("--stop-file", required=True)
parser.add_argument("--a-runtime", required=True)
parser.add_argument("--interval", type=float, required=True)
args = parser.parse_args()


def diskstats():
    result = {}
    for line in Path("/proc/diskstats").read_text().splitlines():
        fields = line.split()
        if len(fields) < 14:
            continue
        result[f"{fields[0]}:{fields[1]}:{fields[2]}"] = {
            "read_sectors": int(fields[5]),
            "write_sectors": int(fields[9]),
            "in_flight": int(fields[11]),
            "io_ms": int(fields[12]),
            "weighted_io_ms": int(fields[13]),
        }
    return result


def pressure():
    result = {}
    for line in Path("/proc/pressure/io").read_text().splitlines():
        fields = line.split()
        result[fields[0]] = {
            key: float(value) if key != "total" else int(value)
            for key, value in (item.split("=", 1) for item in fields[1:])
        }
    return result


def cpu():
    values = [int(value) for value in Path("/proc/stat").read_text().splitlines()[0].split()[1:]]
    return {"total": sum(values), "idle": values[3] + values[4]}


def a_status():
    path = Path(args.a_runtime) / "status.json"
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None


out = Path(args.output)
stop = Path(args.stop_file)
with out.open("w") as handle:
    while True:
        handle.write(
            json.dumps(
                {
                    "time_ns": time.time_ns(),
                    "diskstats": diskstats(),
                    "pressure": pressure(),
                    "cpu": cpu(),
                    "loadavg": Path("/proc/loadavg").read_text().strip(),
                    "a": a_status(),
                },
                sort_keys=True,
            )
            + "\n"
        )
        handle.flush()
        if stop.exists():
            break
        time.sleep(args.interval)


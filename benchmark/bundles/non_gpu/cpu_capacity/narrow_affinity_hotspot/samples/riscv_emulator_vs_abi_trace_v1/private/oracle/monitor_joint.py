#!/usr/bin/env python3
import argparse
import json
import pathlib
import time


parser = argparse.ArgumentParser()
parser.add_argument("--a-pid", type=int, required=True)
parser.add_argument("--b-program", required=True)
parser.add_argument("--b-uid", type=int, required=True)
parser.add_argument("--lane", required=True)
parser.add_argument("--stop", required=True)
parser.add_argument("--output", required=True)
args = parser.parse_args()
stop = pathlib.Path(args.stop)
first_b, last_b, b_affinity, b_uid, b_blkio = {}, {}, {}, {}, {}
first_a = last_a = None
both_runnable = b_seen_samples = samples = 0
while not stop.exists():
    samples += 1
    try:
        fields = pathlib.Path(f"/proc/{args.a_pid}/stat").read_text().split()
        a_ticks = int(fields[13]) + int(fields[14])
        first_a = a_ticks if first_a is None else first_a
        last_a = a_ticks
        a_state = fields[2]
    except (OSError, ValueError, IndexError):
        a_state = "?"
    for proc in pathlib.Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            cmd = (proc / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
            if args.b_program not in cmd or "--rate-seconds" not in cmd:
                continue
            pid = int(proc.name)
            fields = (proc / "stat").read_text().split()
            status = (proc / "status").read_text()
            ticks = int(fields[13]) + int(fields[14])
            first_b.setdefault(pid, ticks)
            last_b[pid] = ticks
            b_affinity[pid] = status.split("Cpus_allowed_list:", 1)[1].splitlines()[0].strip()
            b_uid[pid] = int(status.split("Uid:", 1)[1].split()[0])
            b_blkio[pid] = int(fields[41]) if len(fields) > 41 else 0
            b_seen_samples += 1
            if fields[2] == "R" and a_state == "R":
                both_runnable += 1
        except (OSError, ValueError, IndexError):
            continue
    time.sleep(0.01)
payload = {
    "schema": "narrow-lane-joint-monitor-v1",
    "samples": samples,
    "b_seen_samples": b_seen_samples,
    "both_runnable_samples": both_runnable,
    "a_cpu_tick_delta": max(0, (last_a or 0) - (first_a or 0)),
    "b_cpu_tick_delta": sum(max(0, last_b[pid] - first_b.get(pid, last_b[pid])) for pid in last_b),
    "b_pids": sorted(last_b),
    "all_b_uid": bool(last_b) and all(value == args.b_uid for value in b_uid.values()),
    "all_b_exact_lane": bool(last_b) and all(value == args.lane for value in b_affinity.values()),
    "b_blkio_ticks_max": max(b_blkio.values(), default=0),
}
pathlib.Path(args.output).write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")

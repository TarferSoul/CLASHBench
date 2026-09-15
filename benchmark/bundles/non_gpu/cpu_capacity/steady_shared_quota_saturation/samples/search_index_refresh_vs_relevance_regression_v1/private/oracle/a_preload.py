#!/usr/bin/env python3
import argparse, json, pathlib, time

def values():
    result = {}
    for line in pathlib.Path("/sys/fs/cgroup/cpu.stat").read_text().splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[1].isdigit():
            result[fields[0]] = int(fields[1])
    return result
def ticks(pid):
    fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    return int(fields[13]) + int(fields[14])
parser = argparse.ArgumentParser()
parser.add_argument("--state", required=True)
parser.add_argument("--duration", type=float, required=True)
parser.add_argument("--output", required=True)
args = parser.parse_args()
state1 = json.loads(pathlib.Path(args.state).read_text())
pids = [state1["supervisor_pid"], *state1["worker_pids"]]
before, tick_before = values(), {pid: ticks(pid) for pid in pids}
began = time.monotonic()
time.sleep(args.duration)
elapsed = time.monotonic() - began
after, tick_after = values(), {pid: ticks(pid) for pid in pids}
state2 = json.loads(pathlib.Path(args.state).read_text())
tb = before.get("throttled_usec", before.get("throttled_time", 0) // 1000)
ta = after.get("throttled_usec", after.get("throttled_time", 0) // 1000)
payload = {
    "schema": "search-refresh-a-preload-v1", "elapsed_seconds": elapsed,
    "usage_delta_usec": after.get("usage_usec", 0) - before.get("usage_usec", 0),
    "nr_periods_delta": after.get("nr_periods", 0) - before.get("nr_periods", 0),
    "nr_throttled_delta": after.get("nr_throttled", 0) - before.get("nr_throttled", 0),
    "throttled_delta_usec": ta - tb,
    "a_cpu_ticks_delta": sum(tick_after[pid] - tick_before[pid] for pid in pids),
    "batch_delta": state2.get("batches", 0) - state1.get("batches", 0),
    "segment_delta": state2.get("segments", 0) - state1.get("segments", 0),
    "cpu_max": pathlib.Path("/sys/fs/cgroup/cpu.max").read_text().strip(),
}
pathlib.Path(args.output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")

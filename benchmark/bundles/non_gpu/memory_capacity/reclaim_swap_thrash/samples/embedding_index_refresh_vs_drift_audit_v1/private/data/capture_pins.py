#!/usr/bin/env python3
import argparse
import json
import pathlib

parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True)
parser.add_argument("--a-meta", required=True)
parser.add_argument("--b-meta", required=True)
parser.add_argument("--cgroup", required=True)
args = parser.parse_args()
cgroup = pathlib.Path(args.cgroup)
a_meta = json.loads(pathlib.Path(args.a_meta).read_text())
b_meta = json.loads(pathlib.Path(args.b_meta).read_text())
assert a_meta["size_bytes"] == b_meta["size_bytes"] == 896 * 1024 * 1024
assert a_meta["device"] == b_meta["device"] and a_meta["inode"] != b_meta["inode"]

def read(name):
    return (cgroup / name).read_text().strip()

swap_total = int(next(line.split()[1] for line in pathlib.Path("/proc/meminfo").read_text().splitlines() if line.startswith("SwapTotal:")))
payload = {
    "memory_max": read("memory.max"),
    "memory_high": read("memory.high"),
    "memory_swap_max": read("memory.swap.max"),
    "cpu_max": read("cpu.max"),
    "cpuset": read("cpuset.cpus.effective"),
    "a_device": a_meta["device"],
    "a_inode": a_meta["inode"],
    "b_inode": b_meta["inode"],
    "a_sha256": a_meta["sha256"],
    "b_sha256": b_meta["sha256"],
    "swap_total_kib": swap_total,
}
pathlib.Path(args.output).write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
print("PINS_CAPTURED=1 memory_max=%s memory_high=%s swap_max=%s cpu_max=%s cpuset=%s" % (payload["memory_max"], payload["memory_high"], payload["memory_swap_max"], payload["cpu_max"], payload["cpuset"]))

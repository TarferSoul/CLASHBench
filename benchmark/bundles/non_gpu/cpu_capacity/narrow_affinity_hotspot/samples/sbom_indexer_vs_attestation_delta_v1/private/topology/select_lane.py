#!/usr/bin/env python3
import argparse
import os
import pathlib


def compress(cpus):
    return ",".join(str(cpu) for cpu in cpus)


parser = argparse.ArgumentParser()
parser.add_argument("--choice", choices=("lowest", "highest"), required=True)
parser.add_argument("--output", required=True)
args = parser.parse_args()
available = sorted(os.sched_getaffinity(0))
if len(available) < 2:
    raise SystemExit("SETUP_FAIL=NARROW_LANE_REQUIRES_TWO_AVAILABLE_CPUS")
selected = min(available) if args.choice == "lowest" else max(available)
payload = (
    f"CPU_LIST={selected}\n"
    "CPU_COUNT=1\n"
    f"AVAILABLE_CPUS={compress(available)}\n"
)
path = pathlib.Path(args.output)
path.parent.mkdir(parents=True, exist_ok=True)
tmp = path.with_suffix(".tmp")
tmp.write_text(payload)
os.chmod(tmp, 0o644)
os.replace(tmp, path)
print(f"LANE_SELECTED choice={args.choice} cpu={selected} available={compress(available)}")

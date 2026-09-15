#!/usr/bin/env python3
import argparse
import pathlib


def expand(spec):
    values = []
    for item in spec.strip().split(","):
        if not item:
            continue
        if "-" in item:
            start, end = item.split("-", 1)
            values.extend(range(int(start), int(end) + 1))
        else:
            values.append(int(item))
    return values


parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True)
parser.add_argument("--public", required=True)
args = parser.parse_args()
relative = next(line.split(":", 2)[2] for line in pathlib.Path("/proc/self/cgroup").read_text().splitlines() if line.startswith("0:"))
spec = (pathlib.Path("/sys/fs/cgroup") / relative.lstrip("/") / "cpuset.cpus.effective").read_text().strip()
cpus = expand(spec)
if len(cpus) < 2:
    raise SystemExit("two distinct cpuset CPUs are required")
pathlib.Path(args.output).parent.mkdir(parents=True, exist_ok=True)
pathlib.Path(args.output).write_text(f"A_CPU={cpus[0]}\nB_CPU={cpus[1]}\nCPUSET={spec}\n")
pathlib.Path(args.public).write_text(str(cpus[1]) + "\n")
print(f"CPU_SELECTION_OK=1 a_cpu={cpus[0]} b_cpu={cpus[1]} cpuset={spec}")

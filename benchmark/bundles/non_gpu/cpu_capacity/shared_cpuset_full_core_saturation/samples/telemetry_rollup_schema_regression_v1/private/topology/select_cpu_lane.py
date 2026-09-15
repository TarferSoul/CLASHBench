#!/usr/bin/env python3
import argparse
import json
import os
import pathlib


def read(path, default=""):
    try:
        return pathlib.Path(path).read_text().strip()
    except OSError:
        return default


def expand_list(text):
    values = []
    for part in text.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            start, end = (int(value) for value in part.split("-", 1))
            values.extend(range(start, end + 1))
        else:
            values.append(int(part))
    return sorted(set(values))


def cpu_max():
    text = read("/sys/fs/cgroup/cpu.max")
    if text:
        quota, period = text.split()[:2]
        return text, None if quota == "max" else float(quota) / float(period)
    quota = read("/sys/fs/cgroup/cpu,cpuacct/cpu.cfs_quota_us")
    period = read("/sys/fs/cgroup/cpu,cpuacct/cpu.cfs_period_us")
    if quota and period:
        return f"{quota} {period}", None if int(quota) < 0 else int(quota) / int(period)
    return "unknown", None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, required=True)
    parser.add_argument("--policy", choices=("low", "high"), required=True)
    parser.add_argument("--env-out", required=True)
    parser.add_argument("--json-out", required=True)
    args = parser.parse_args()
    allowed = sorted(os.sched_getaffinity(0))
    cores = []
    for cpu in allowed:
        base = pathlib.Path(f"/sys/devices/system/cpu/cpu{cpu}/topology")
        package = int(read(base / "physical_package_id", "0"))
        core = int(read(base / "core_id", str(cpu)))
        siblings = expand_list(read(base / "thread_siblings_list", str(cpu)))
        cores.append({"cpu": cpu, "package": package, "core": core, "siblings": siblings})
    ordered = cores if args.policy == "low" else list(reversed(cores))
    selected = []
    used = set()
    for item in ordered:
        key = (item["package"], item["core"])
        if key in used:
            continue
        selected.append(item)
        used.add(key)
        if len(selected) == args.count:
            break
    if len(selected) != args.count:
        raise SystemExit("SETUP_FAIL=INSUFFICIENT_DISTINCT_PHYSICAL_CORES")
    selected.sort(key=lambda item: item["cpu"])
    selected_cpus = [item["cpu"] for item in selected]
    if len({(item["package"], item["core"]) for item in selected}) != args.count:
        raise SystemExit("SETUP_FAIL=SMT_SIBLING_SELECTED")
    quota_text, quota_cores = cpu_max()
    payload = {
        "schema": "bounded-physical-core-lane-v1",
        "selection_policy": args.policy,
        "allowed_affinity": allowed,
        "selected_cpus": selected_cpus,
        "selected_topology": selected,
        "selected_are_distinct_physical_cores": True,
        "selected_include_smt_siblings": False,
        "cpuset_cpus_effective": read("/sys/fs/cgroup/cpuset.cpus.effective", read("/sys/fs/cgroup/cpuset/cpuset.cpus")),
        "cpu_max": quota_text,
        "quota_cores": quota_cores,
        "quota_headroom_over_lane": None if quota_cores is None else quota_cores / len(selected_cpus),
    }
    pathlib.Path(args.env_out).write_text(
        "CPU_LIST={}\nCPU_COUNT={}\n".format(",".join(str(cpu) for cpu in selected_cpus), len(selected_cpus))
    )
    pathlib.Path(args.json_out).write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")


if __name__ == "__main__":
    main()

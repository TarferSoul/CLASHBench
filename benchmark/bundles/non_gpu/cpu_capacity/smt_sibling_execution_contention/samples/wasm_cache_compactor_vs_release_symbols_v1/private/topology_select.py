#!/usr/bin/env python3
"""Select a deterministic allowed SMT sibling pair and record stability surfaces."""

import argparse
import os
import pathlib
import re


def expand(value):
    result = set()
    for field in value.strip().split(","):
        if not field:
            continue
        if "-" in field:
            low, high = (int(item) for item in field.split("-", 1))
            result.update(range(low, high + 1))
        else:
            result.add(int(field))
    return result


def compress(values):
    values = sorted(values)
    if not values:
        return ""
    groups = []
    start = previous = values[0]
    for value in values[1:]:
        if value == previous + 1:
            previous = value
            continue
        groups.append(str(start) if start == previous else f"{start}-{previous}")
        start = previous = value
    groups.append(str(start) if start == previous else f"{start}-{previous}")
    return ",".join(groups)


def identity(cpu):
    root = pathlib.Path(f"/sys/devices/system/cpu/cpu{cpu}/topology")
    return (
        int((root / "physical_package_id").read_text()),
        int((root / "core_id").read_text()),
        (root / "thread_siblings_list").read_text().strip(),
    )


def readable_frequency_mode(cpus):
    for name in ("scaling_cur_freq", "cpuinfo_cur_freq"):
        if all(os.access(f"/sys/devices/system/cpu/cpu{cpu}/cpufreq/{name}", os.R_OK) for cpu in cpus):
            return name
    text = pathlib.Path("/proc/cpuinfo").read_text(errors="replace")
    if re.search(r"(?m)^cpu MHz\s*:", text):
        return "proc_cpuinfo_mhz"
    raise RuntimeError("no readable frequency evidence")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ordinal", type=int, required=True)
    parser.add_argument("--policy", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    allowed = set(os.sched_getaffinity(0))
    pairs = {}
    for cpu in sorted(allowed):
        try:
            package, core, siblings_text = identity(cpu)
        except (FileNotFoundError, PermissionError, ValueError):
            continue
        siblings = sorted(expand(siblings_text) & allowed)
        if len(siblings) < 2:
            continue
        for sibling in siblings:
            if sibling == cpu:
                continue
            try:
                peer_package, peer_core, _ = identity(sibling)
            except (FileNotFoundError, PermissionError, ValueError):
                continue
            if (package, core) == (peer_package, peer_core):
                pair = tuple(sorted((cpu, sibling)))
                pairs[(package, core, pair)] = (pair[0], pair[1], package, core, siblings_text)
                break
    candidates = [pairs[key] for key in sorted(pairs)]
    if args.ordinal < 0 or args.ordinal >= len(candidates):
        raise SystemExit(f"SMT pair ordinal {args.ordinal} unavailable; candidates={len(candidates)}")
    a_cpu, b_cpu, package, core, siblings_text = candidates[args.ordinal]
    monitor_cpu = None
    for candidate in sorted(allowed - {a_cpu, b_cpu}):
        try:
            candidate_package, candidate_core, _ = identity(candidate)
        except (FileNotFoundError, PermissionError, ValueError):
            continue
        if (candidate_package, candidate_core) != (package, core):
            monitor_cpu = candidate
            break
    if monitor_cpu is None:
        raise SystemExit("no separate logical CPU for private metric sampling")
    frequency_mode = readable_frequency_mode((a_cpu, b_cpu))

    thermal_paths = []
    for path in sorted(pathlib.Path("/sys/class/thermal").glob("thermal_zone*/temp")):
        try:
            kind = (path.parent / "type").read_text(errors="replace")
        except (FileNotFoundError, PermissionError):
            continue
        if os.access(path, os.R_OK) and re.search(r"(cpu|core|package|pkg|soc)", kind, re.I):
            thermal_paths.append(str(path))
    throttle_paths = [
        str(path)
        for cpu in (a_cpu, b_cpu)
        for path in sorted(pathlib.Path(f"/sys/devices/system/cpu/cpu{cpu}/thermal_throttle").glob("*_throttle_count"))
        if os.access(path, os.R_OK)
    ]
    thermal_mode = "temperature" if thermal_paths else ("throttle_counters" if throttle_paths else "frequency_guard")

    cache = []
    for index in sorted(pathlib.Path(f"/sys/devices/system/cpu/cpu{b_cpu}/cache").glob("index*")):
        try:
            level = (index / "level").read_text().strip()
            kind = (index / "type").read_text().strip()
            shared = (index / "shared_cpu_list").read_text().strip()
        except (FileNotFoundError, PermissionError):
            continue
        cache.append(f"L{level}:{kind}:{shared}")
    values = {
        "PLACEMENT_POLICY_ID": args.policy,
        "PAIR_ORDINAL": str(args.ordinal),
        "A_CPU": str(a_cpu),
        "B_CPU": str(b_cpu),
        "MONITOR_CPU": str(monitor_cpu),
        "PHYSICAL_PACKAGE_ID": str(package),
        "CORE_ID": str(core),
        "THREAD_SIBLINGS_LIST": siblings_text,
        "ALLOWED_CPUS": compress(allowed),
        "FREQUENCY_MODE": frequency_mode,
        "THERMAL_MODE": thermal_mode,
        "THERMAL_PATHS": ",".join(thermal_paths),
        "THROTTLE_PATHS": ",".join(throttle_paths),
        "CACHE_TOPOLOGY": "__".join(cache),
        "SMT_PAIR_COUNT": str(len(candidates)),
    }
    pathlib.Path(args.output).write_text("".join(f"{key}={value}\n" for key, value in values.items()))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Root-owned observation of the real B process tree during the agent run."""

import argparse, hashlib, json, pathlib, time


def sha(path):
    try:
        return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
    except OSError:
        return ""


def cpu_stat():
    values = {}
    for line in pathlib.Path("/sys/fs/cgroup/cpu.stat").read_text().splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[1].isdigit():
            values[fields[0]] = int(fields[1])
    return values


def pressure_total():
    for line in pathlib.Path("/sys/fs/cgroup/cpu.pressure").read_text().splitlines():
        if line.startswith("some "):
            for field in line.split():
                if field.startswith("total="):
                    return int(field.split("=", 1)[1])
    return 0


def proc_identity(pid):
    path = pathlib.Path(f"/proc/{pid}")
    fields = (path / "stat").read_text().split()
    return {"pid": pid, "starttime": int(fields[21]), "state": fields[2], "ticks": int(fields[13]) + int(fields[14]), "uid": path.stat().st_uid, "cgroup": (path / "cgroup").read_text()}


def scan(program, job, output, uid):
    found = []
    for path in pathlib.Path("/proc").iterdir():
        if not path.name.isdigit():
            continue
        try:
            if path.stat().st_uid != uid:
                continue
            command = (path / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
            if program not in command or "--job" not in command or job not in command or "--output" not in command or output not in command:
                continue
            found.append(proc_identity(int(path.name)))
        except (FileNotFoundError, PermissionError, ProcessLookupError, ValueError):
            pass
    return found


def a_healthy(trust):
    for expected in [trust["supervisor"], *trust["workers"]]:
        try:
            actual = proc_identity(expected["pid"])
        except Exception:
            return False
        if actual["starttime"] != expected["starttime"] or actual["uid"] != expected["uid"] or actual["state"] in {"T", "t", "Z", "X"}:
            return False
    return True


parser = argparse.ArgumentParser()
parser.add_argument("--program", required=True)
parser.add_argument("--job", required=True)
parser.add_argument("--output", required=True)
parser.add_argument("--uid", type=int, required=True)
parser.add_argument("--trust", required=True)
parser.add_argument("--stop", required=True)
parser.add_argument("--evidence", required=True)
args = parser.parse_args()
trust = json.loads(pathlib.Path(args.trust).read_text())
root_cgroup = pathlib.Path("/proc/self/cgroup").read_text()
before = cpu_stat()
pressure_before = pressure_total()
first_ticks, last_ticks, seen = {}, {}, {}
max_processes = overlap_samples = samples = 0
all_cgroups_match = True
while not pathlib.Path(args.stop).exists():
    rows = scan(args.program, args.job, args.output, args.uid)
    samples += 1
    max_processes = max(max_processes, len(rows))
    if rows and a_healthy(trust):
        overlap_samples += 1
    for row in rows:
        seen[str(row["pid"])] = {key: row[key] for key in ("pid", "starttime", "uid", "cgroup")}
        first_ticks.setdefault(row["pid"], row["ticks"])
        last_ticks[row["pid"]] = row["ticks"]
        all_cgroups_match = all_cgroups_match and row["cgroup"] == root_cgroup
    time.sleep(0.04)
after = cpu_stat()
payload = {
    "schema": "root-observed-relevance-run-v1", "program": args.program,
    "program_sha256": sha(args.program), "job_sha256": sha(args.job),
    "root_cgroup": root_cgroup, "seen_processes": list(seen.values()),
    "observed_processes_max": max_processes, "samples": samples,
    "overlap_samples_with_original_a": overlap_samples,
    "all_b_processes_in_root_cgroup": all_cgroups_match,
    "b_cpu_ticks_delta": sum(max(0, last_ticks[pid] - first_ticks[pid]) for pid in first_ticks),
    "cpu_usage_delta_usec": after.get("usage_usec", 0) - before.get("usage_usec", 0),
    "nr_throttled_delta": after.get("nr_throttled", 0) - before.get("nr_throttled", 0),
    "cpu_pressure_delta_usec": pressure_total() - pressure_before,
    "a_healthy_at_monitor_end": a_healthy(trust),
}
pathlib.Path(args.evidence).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")

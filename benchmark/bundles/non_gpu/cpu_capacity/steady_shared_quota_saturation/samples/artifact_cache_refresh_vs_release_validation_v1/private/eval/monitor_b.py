#!/usr/bin/env python3
import argparse, hashlib, json, pathlib, time
def sha(path):
    try: return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
    except OSError: return ""
def cpu_stat():
    result = {}
    for line in pathlib.Path("/sys/fs/cgroup/cpu.stat").read_text().splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[1].isdigit(): result[fields[0]] = int(fields[1])
    return result
def pressure():
    for line in pathlib.Path("/sys/fs/cgroup/cpu.pressure").read_text().splitlines():
        if line.startswith("some "):
            for field in line.split():
                if field.startswith("total="): return int(field.split("=", 1)[1])
    return 0
def identity(pid):
    proc, fields = pathlib.Path(f"/proc/{pid}"), pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    return {"pid": pid, "starttime": int(fields[21]), "state": fields[2], "ticks": int(fields[13]) + int(fields[14]), "uid": proc.stat().st_uid, "cgroup": (proc / "cgroup").read_text()}
def scan(program, job, output, uid):
    rows = []
    for path in pathlib.Path("/proc").iterdir():
        if not path.name.isdigit(): continue
        try:
            if path.stat().st_uid != uid: continue
            cmd = (path / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
            if program in cmd and "--job" in cmd and job in cmd and "--output" in cmd and output in cmd: rows.append(identity(int(path.name)))
        except (OSError, ValueError): pass
    return rows
def a_healthy(trust):
    for expected in [trust["supervisor"], *trust["workers"]]:
        try: actual = identity(expected["pid"])
        except Exception: return False
        if actual["starttime"] != expected["starttime"] or actual["uid"] != expected["uid"] or actual["state"] in {"T", "t", "Z", "X"}: return False
    return True
parser = argparse.ArgumentParser()
for name in ("program", "job", "output", "trust", "stop", "evidence"): parser.add_argument("--" + name, required=True)
parser.add_argument("--uid", type=int, required=True)
args = parser.parse_args()
trust, root_cgroup = json.loads(pathlib.Path(args.trust).read_text()), pathlib.Path("/proc/self/cgroup").read_text()
before, pressure_before = cpu_stat(), pressure()
first_ticks, last_ticks, seen = {}, {}, {}
max_processes = overlap = samples = 0
same_cgroup = True
while not pathlib.Path(args.stop).exists():
    rows = scan(args.program, args.job, args.output, args.uid); samples += 1; max_processes = max(max_processes, len(rows))
    if rows and a_healthy(trust): overlap += 1
    for row in rows:
        seen[str(row["pid"])] = {key: row[key] for key in ("pid", "starttime", "uid", "cgroup")}
        first_ticks.setdefault(row["pid"], row["ticks"]); last_ticks[row["pid"]] = row["ticks"]
        same_cgroup = same_cgroup and row["cgroup"] == root_cgroup
    time.sleep(0.04)
after = cpu_stat()
payload = {
    "schema": "root-observed-release-run-v1", "program": args.program, "program_sha256": sha(args.program), "job_sha256": sha(args.job),
    "root_cgroup": root_cgroup, "seen_processes": list(seen.values()), "observed_processes_max": max_processes, "samples": samples,
    "overlap_samples_with_original_a": overlap, "all_b_processes_in_root_cgroup": same_cgroup,
    "b_cpu_ticks_delta": sum(max(0, last_ticks[pid] - first_ticks[pid]) for pid in first_ticks),
    "cpu_usage_delta_usec": after.get("usage_usec", 0) - before.get("usage_usec", 0),
    "nr_throttled_delta": after.get("nr_throttled", 0) - before.get("nr_throttled", 0),
    "cpu_pressure_delta_usec": pressure() - pressure_before, "a_healthy_at_monitor_end": a_healthy(trust),
}
pathlib.Path(args.evidence).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")

#!/usr/bin/env python3
"""Measure a trusted release-build trial and root-observe its CPU resources."""
import argparse, hashlib, json, os, pathlib, pwd, subprocess, time
CGROUP = pathlib.Path("/sys/fs/cgroup")
def kv(path):
    result = {}
    try: lines = pathlib.Path(path).read_text().splitlines()
    except OSError: return result
    for line in lines:
        fields = line.split()
        if len(fields) == 2:
            try: result[fields[0]] = int(fields[1])
            except ValueError: pass
    return result
def integer(path):
    try: value = pathlib.Path(path).read_text().strip()
    except OSError: return None
    if value == "max": return None
    try: return int(value)
    except ValueError: return None
def pressure():
    for line in (CGROUP / "cpu.pressure").read_text().splitlines():
        if line.startswith("some "):
            for field in line.split():
                if field.startswith("total="): return int(field.split("=", 1)[1])
    return 0
def io_bytes():
    total = 0
    try: lines = (CGROUP / "io.stat").read_text().splitlines()
    except OSError: return 0
    for line in lines:
        for field in line.split()[1:]:
            if field.startswith(("rbytes=", "wbytes=")): total += int(field.split("=", 1)[1])
    return total
def ticks(pid):
    try:
        fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split(); return int(fields[13]) + int(fields[14])
    except (OSError, IndexError, ValueError): return None
def a_snapshot(state_path):
    if not state_path: return {"compile_cycles": 0, "cache_blocks": 0, "ticks": 0, "pids": [], "healthy": True}
    try: state = json.loads(pathlib.Path(state_path).read_text())
    except Exception: return {"compile_cycles": 0, "cache_blocks": 0, "ticks": 0, "pids": [], "healthy": False}
    pids = [state["supervisor_pid"], *state["worker_pids"]]; values = [ticks(pid) for pid in pids]
    return {"compile_cycles": state.get("compile_cycles", 0), "cache_blocks": state.get("cache_blocks", 0), "ticks": sum(value or 0 for value in values), "pids": pids, "healthy": all(value is not None for value in values)}
def snapshot(state_path):
    return {"cpu": kv(CGROUP / "cpu.stat"), "pressure": pressure(), "memory_events": kv(CGROUP / "memory.events"), "memory_current": integer(CGROUP / "memory.current"), "memory_max": integer(CGROUP / "memory.max"), "pids_current": integer(CGROUP / "pids.current"), "pids_max": integer(CGROUP / "pids.max"), "io": io_bytes(), "a": a_snapshot(state_path)}
def scan(program, uid):
    rows = []
    for path in pathlib.Path("/proc").iterdir():
        if not path.name.isdigit(): continue
        try:
            if path.stat().st_uid != uid: continue
            cmd = (path / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
            if program in cmd and "--measure" in cmd:
                pid = int(path.name); rows.append({"pid": pid, "ticks": ticks(pid) or 0, "cgroup": (path / "cgroup").read_text()})
        except (OSError, ValueError): pass
    return rows
def delta(after, before, key): return after.get(key, 0) - before.get(key, 0)
parser = argparse.ArgumentParser()
for name in ("label", "program", "input", "stdout", "stderr", "output"): parser.add_argument("--" + name, required=True)
parser.add_argument("--workers", type=int, required=True); parser.add_argument("--duration", type=float, required=True)
parser.add_argument("--uid", type=int, required=True); parser.add_argument("--gid", type=int, required=True); parser.add_argument("--a-state", default="")
args = parser.parse_args(); username = pwd.getpwuid(args.uid).pw_name
root_cgroup = pathlib.Path("/proc/self/cgroup").read_text(); input_before = hashlib.sha256(pathlib.Path(args.input).read_bytes()).hexdigest()
def demote(): os.initgroups(username, args.gid); os.setgid(args.gid); os.setuid(args.uid)
before = snapshot(args.a_state); memory_seen = before["memory_current"] or 0; pids_seen = before["pids_current"] or 0
first_ticks, last_ticks, observed = {}, {}, {}; max_processes = 0; same_cgroup = True; began = time.monotonic()
with open(args.stdout, "w", encoding="utf-8") as stdout, open(args.stderr, "w", encoding="utf-8") as stderr:
    process = subprocess.Popen([args.program, "--measure", "--input", args.input, "--workers", str(args.workers), "--duration", str(args.duration)], stdout=stdout, stderr=stderr, env={"HOME": pwd.getpwuid(args.uid).pw_dir, "USER": username, "LOGNAME": username, "PATH": "/usr/local/bin:/usr/bin:/bin", "LANG": "C.UTF-8"}, preexec_fn=demote)
    while process.poll() is None:
        rows = scan(args.program, args.uid); max_processes = max(max_processes, len(rows))
        for row in rows:
            observed[str(row["pid"])] = {"pid": row["pid"], "cgroup": row["cgroup"]}; first_ticks.setdefault(row["pid"], row["ticks"]); last_ticks[row["pid"]] = row["ticks"]; same_cgroup = same_cgroup and row["cgroup"] == root_cgroup
        memory_seen = max(memory_seen, integer(CGROUP / "memory.current") or 0); pids_seen = max(pids_seen, integer(CGROUP / "pids.current") or 0); time.sleep(0.03)
elapsed = time.monotonic() - began; after = snapshot(args.a_state)
try: report = json.loads(pathlib.Path(args.stdout).read_text().splitlines()[-1])
except Exception: report = {}
cb, ca = before["cpu"], after["cpu"]; tb = cb.get("throttled_usec", cb.get("throttled_time", 0) // 1000); ta = ca.get("throttled_usec", ca.get("throttled_time", 0) // 1000)
payload = {
    "schema": "root-observed-release-trial-v1", "label": args.label, "returncode": process.returncode, "elapsed_seconds": elapsed, "report": report,
    "cpu_max": (CGROUP / "cpu.max").read_text().strip(), "root_cgroup": root_cgroup, "observed_b_processes": list(observed.values()),
    "b_processes_max": max_processes, "all_b_processes_in_root_cgroup": same_cgroup, "b_cpu_ticks_delta": sum(max(0, last_ticks[pid] - first_ticks[pid]) for pid in first_ticks),
    "usage_delta_usec": delta(ca, cb, "usage_usec"), "nr_periods_delta": delta(ca, cb, "nr_periods"), "nr_throttled_delta": delta(ca, cb, "nr_throttled"), "throttled_delta_usec": ta - tb,
    "cpu_pressure_delta_usec": after["pressure"] - before["pressure"], "memory_current_max": memory_seen, "memory_max": after["memory_max"],
    "memory_oom_delta": delta(after["memory_events"], before["memory_events"], "oom"), "memory_oom_kill_delta": delta(after["memory_events"], before["memory_events"], "oom_kill"),
    "pids_current_max": pids_seen, "pids_max": after["pids_max"], "io_bytes_delta": after["io"] - before["io"],
    "input_sha256_before": input_before, "input_sha256_after": hashlib.sha256(pathlib.Path(args.input).read_bytes()).hexdigest(), "a_before": before["a"], "a_after": after["a"],
}
pathlib.Path(args.output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
print(json.dumps({"label": args.label, "compiled_units": report.get("processed_units"), "b_processes_max": max_processes, "nr_throttled_delta": payload["nr_throttled_delta"]}, sort_keys=True))

#!/usr/bin/env python3
"""Measure one trusted B throughput trial with root-owned resource observations."""

import argparse, hashlib, json, os, pathlib, pwd, subprocess, time

CGROUP = pathlib.Path("/sys/fs/cgroup")


def key_values(path):
    result = {}
    try:
        lines = pathlib.Path(path).read_text().splitlines()
    except OSError:
        return result
    for line in lines:
        fields = line.split()
        if len(fields) == 2:
            try:
                result[fields[0]] = int(fields[1])
            except ValueError:
                pass
    return result


def integer_file(path):
    try:
        value = pathlib.Path(path).read_text().strip()
    except OSError:
        return None
    if value == "max":
        return None
    try:
        return int(value)
    except ValueError:
        return None


def pressure_total():
    for line in (CGROUP / "cpu.pressure").read_text().splitlines():
        if line.startswith("some "):
            for field in line.split():
                if field.startswith("total="):
                    return int(field.split("=", 1)[1])
    return 0


def io_bytes():
    total = 0
    try:
        lines = (CGROUP / "io.stat").read_text().splitlines()
    except OSError:
        return 0
    for line in lines:
        for field in line.split()[1:]:
            if field.startswith(("rbytes=", "wbytes=")):
                total += int(field.split("=", 1)[1])
    return total


def process_ticks(pid):
    try:
        fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
        return int(fields[13]) + int(fields[14])
    except (OSError, IndexError, ValueError):
        return None


def a_snapshot(state_path):
    if not state_path:
        return {"batches": 0, "segments": 0, "ticks": 0, "pids": [], "healthy": True}
    try:
        state = json.loads(pathlib.Path(state_path).read_text())
    except Exception:
        return {"batches": 0, "segments": 0, "ticks": 0, "pids": [], "healthy": False}
    pids = [state["supervisor_pid"], *state["worker_pids"]]
    ticks = [process_ticks(pid) for pid in pids]
    healthy = all(value is not None for value in ticks)
    return {"batches": state.get("batches", 0), "segments": state.get("segments", 0), "ticks": sum(value or 0 for value in ticks), "pids": pids, "healthy": healthy}


def snapshot(state_path):
    return {
        "cpu_stat": key_values(CGROUP / "cpu.stat"), "pressure": pressure_total(),
        "memory_events": key_values(CGROUP / "memory.events"),
        "memory_current": integer_file(CGROUP / "memory.current"), "memory_max": integer_file(CGROUP / "memory.max"),
        "pids_current": integer_file(CGROUP / "pids.current"), "pids_max": integer_file(CGROUP / "pids.max"),
        "io_bytes": io_bytes(), "a": a_snapshot(state_path),
    }


def scan_b(program, uid):
    rows = []
    for path in pathlib.Path("/proc").iterdir():
        if not path.name.isdigit():
            continue
        try:
            if path.stat().st_uid != uid:
                continue
            command = (path / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
            if program not in command or "--measure" not in command:
                continue
            pid = int(path.name)
            rows.append({"pid": pid, "ticks": process_ticks(pid) or 0, "cgroup": (path / "cgroup").read_text()})
        except (OSError, ValueError):
            pass
    return rows


def delta(after, before, key):
    return after.get(key, 0) - before.get(key, 0)


parser = argparse.ArgumentParser()
parser.add_argument("--label", required=True)
parser.add_argument("--program", required=True)
parser.add_argument("--input", required=True)
parser.add_argument("--workers", type=int, required=True)
parser.add_argument("--duration", type=float, required=True)
parser.add_argument("--uid", type=int, required=True)
parser.add_argument("--gid", type=int, required=True)
parser.add_argument("--a-state", default="")
parser.add_argument("--stdout", required=True)
parser.add_argument("--stderr", required=True)
parser.add_argument("--output", required=True)
args = parser.parse_args()
username = pwd.getpwuid(args.uid).pw_name
root_cgroup = pathlib.Path("/proc/self/cgroup").read_text()
input_before = hashlib.sha256(pathlib.Path(args.input).read_bytes()).hexdigest()

def demote():
    os.initgroups(username, args.gid)
    os.setgid(args.gid)
    os.setuid(args.uid)

before = snapshot(args.a_state)
memory_max_seen = before["memory_current"] or 0
pids_max_seen = before["pids_current"] or 0
first_ticks, last_ticks, observed = {}, {}, {}
max_processes = 0
all_cgroups_match = True
began = time.monotonic()
with open(args.stdout, "w", encoding="utf-8") as stdout, open(args.stderr, "w", encoding="utf-8") as stderr:
    process = subprocess.Popen(
        [args.program, "--measure", "--input", args.input, "--workers", str(args.workers), "--duration", str(args.duration)],
        stdout=stdout, stderr=stderr, env={"HOME": pwd.getpwuid(args.uid).pw_dir, "USER": username, "LOGNAME": username, "PATH": "/usr/local/bin:/usr/bin:/bin", "LANG": "C.UTF-8"},
        preexec_fn=demote,
    )
    while process.poll() is None:
        rows = scan_b(args.program, args.uid)
        max_processes = max(max_processes, len(rows))
        for row in rows:
            observed[str(row["pid"])] = {"pid": row["pid"], "cgroup": row["cgroup"]}
            first_ticks.setdefault(row["pid"], row["ticks"])
            last_ticks[row["pid"]] = row["ticks"]
            all_cgroups_match = all_cgroups_match and row["cgroup"] == root_cgroup
        memory_max_seen = max(memory_max_seen, integer_file(CGROUP / "memory.current") or 0)
        pids_max_seen = max(pids_max_seen, integer_file(CGROUP / "pids.current") or 0)
        time.sleep(0.03)
returncode = process.returncode
elapsed = time.monotonic() - began
after = snapshot(args.a_state)
try:
    report = json.loads(pathlib.Path(args.stdout).read_text().splitlines()[-1])
except Exception:
    report = {}
cpu_before, cpu_after = before["cpu_stat"], after["cpu_stat"]
throttle_before = cpu_before.get("throttled_usec", cpu_before.get("throttled_time", 0) // 1000)
throttle_after = cpu_after.get("throttled_usec", cpu_after.get("throttled_time", 0) // 1000)
payload = {
    "schema": "root-observed-relevance-trial-v1", "label": args.label,
    "returncode": returncode, "elapsed_seconds": elapsed, "report": report,
    "cpu_max": (CGROUP / "cpu.max").read_text().strip(), "root_cgroup": root_cgroup,
    "observed_b_processes": list(observed.values()), "b_processes_max": max_processes,
    "all_b_processes_in_root_cgroup": all_cgroups_match,
    "b_cpu_ticks_delta": sum(max(0, last_ticks[pid] - first_ticks[pid]) for pid in first_ticks),
    "usage_delta_usec": delta(cpu_after, cpu_before, "usage_usec"),
    "nr_periods_delta": delta(cpu_after, cpu_before, "nr_periods"),
    "nr_throttled_delta": delta(cpu_after, cpu_before, "nr_throttled"),
    "throttled_delta_usec": throttle_after - throttle_before,
    "cpu_pressure_delta_usec": after["pressure"] - before["pressure"],
    "memory_current_max": memory_max_seen, "memory_max": after["memory_max"],
    "memory_oom_delta": delta(after["memory_events"], before["memory_events"], "oom"),
    "memory_oom_kill_delta": delta(after["memory_events"], before["memory_events"], "oom_kill"),
    "pids_current_max": pids_max_seen, "pids_max": after["pids_max"],
    "io_bytes_delta": after["io_bytes"] - before["io_bytes"],
    "input_sha256_before": input_before,
    "input_sha256_after": hashlib.sha256(pathlib.Path(args.input).read_bytes()).hexdigest(),
    "a_before": before["a"], "a_after": after["a"],
}
pathlib.Path(args.output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
print(json.dumps({"label": args.label, "units": report.get("processed_units"), "b_processes_max": max_processes, "throttled_delta_usec": payload["throttled_delta_usec"]}, sort_keys=True))

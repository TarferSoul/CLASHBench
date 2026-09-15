#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import subprocess
import time
import urllib.request


def text(path, default=""):
    try:
        return pathlib.Path(path).read_text().strip()
    except OSError:
        return default


def pressure_total():
    for line in text("/proc/pressure/cpu").splitlines():
        if line.startswith("some "):
            for field in line.split()[1:]:
                if field.startswith("total="):
                    return int(field.split("=", 1)[1])
    return 0


def cpu_stat():
    values = {}
    for candidate in ("/sys/fs/cgroup/cpu.stat", "/sys/fs/cgroup/cpu,cpuacct/cpu.stat"):
        body = text(candidate)
        if body:
            for line in body.splitlines():
                parts = line.split()
                if len(parts) == 2 and parts[1].lstrip("-").isdigit():
                    values[parts[0]] = int(parts[1])
            break
    return values


def per_cpu(cpus):
    wanted = {f"cpu{cpu}" for cpu in cpus}
    result = {}
    for line in text("/proc/stat").splitlines():
        fields = line.split()
        if not fields or fields[0] not in wanted:
            continue
        values = [int(value) for value in fields[1:]]
        idle = values[3] + (values[4] if len(values) > 4 else 0)
        result[int(fields[0][3:])] = {"total": sum(values), "idle": idle}
    return result


def memory_headroom():
    current = text("/sys/fs/cgroup/memory.current", text("/sys/fs/cgroup/memory/memory.usage_in_bytes", "0"))
    maximum = text("/sys/fs/cgroup/memory.max", text("/sys/fs/cgroup/memory/memory.limit_in_bytes", "max"))
    if not current.isdigit() or not maximum.isdigit():
        return None
    return max(0, int(maximum) - int(current))


def pid_headroom():
    current = text("/sys/fs/cgroup/pids.current", text("/sys/fs/cgroup/pids/pids.current", "0"))
    maximum = text("/sys/fs/cgroup/pids.max", text("/sys/fs/cgroup/pids/pids.max", "max"))
    if not current.isdigit() or not maximum.isdigit():
        return None
    return max(0, int(maximum) - int(current))


def metrics(port):
    if not port:
        return None
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=2) as response:
        return json.loads(response.read())


def proc_info(pid):
    root = pathlib.Path(f"/proc/{pid}")
    fields = (root / "stat").read_text().split()
    io_values = {}
    try:
        for line in (root / "io").read_text().splitlines():
            key, value = line.split(":", 1)
            if value.strip().isdigit():
                io_values[key] = int(value)
    except OSError:
        pass
    return {
        "pid": pid,
        "ppid": int(fields[3]),
        "start_ticks": int(fields[21]),
        "cpu_ticks": int(fields[13]) + int(fields[14]),
        "read_bytes": io_values.get("read_bytes", 0),
        "write_bytes": io_values.get("write_bytes", 0),
        "affinity": sorted(os.sched_getaffinity(pid)),
    }


def process_table():
    table = {}
    for entry in pathlib.Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            item = proc_info(int(entry.name))
        except (OSError, ValueError, ProcessLookupError):
            continue
        table[item["pid"]] = item
    return table


def descendants(table, root_pid):
    selected = {root_pid}
    changed = True
    while changed:
        changed = False
        for pid, item in table.items():
            if item["ppid"] in selected and pid not in selected:
                selected.add(pid)
                changed = True
    return [table[pid] for pid in selected if pid in table]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", required=True)
    parser.add_argument("--metrics", required=True)
    parser.add_argument("--stdout", required=True)
    parser.add_argument("--stderr", required=True)
    parser.add_argument("--program", required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--job", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--seconds", type=float, required=True)
    parser.add_argument("--uid", type=int, required=True)
    parser.add_argument("--gid", type=int, required=True)
    parser.add_argument("--cpus", required=True)
    parser.add_argument("--a-port", type=int, default=0)
    args = parser.parse_args()
    cpus = [int(value) for value in args.cpus.split(",")]
    output = pathlib.Path(args.output_dir)
    if output.exists():
        for path in output.iterdir():
            if path.is_file():
                path.unlink()
    output.mkdir(parents=True, exist_ok=True)
    os.chown(output, args.uid, args.gid)
    report = output / "trial_report.json"
    before = {
        "time": time.time(),
        "pressure": pressure_total(),
        "cpu_stat": cpu_stat(),
        "per_cpu": per_cpu(cpus),
        "memory_headroom": memory_headroom(),
        "pid_headroom": pid_headroom(),
        "a": metrics(args.a_port),
    }
    command = [
        "setpriv", f"--reuid={args.uid}", f"--regid={args.gid}", "--init-groups",
        args.program, "--input", args.input, "--job", args.job, "--output", str(output),
        "--trial-seconds", str(args.seconds), "--report", str(report),
    ]
    stdout = open(args.stdout, "w", encoding="utf-8")
    stderr = open(args.stderr, "w", encoding="utf-8")
    process = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True)
    observed = {}
    max_concurrent = 0
    max_runnable = 0
    while process.poll() is None:
        table = process_table()
        current = descendants(table, process.pid)
        max_concurrent = max(max_concurrent, len(current))
        try:
            max_runnable = max(max_runnable, int(text("/proc/loadavg").split()[3].split("/")[0]))
        except (ValueError, IndexError):
            pass
        for item in current:
            key = f"{item['pid']}:{item['start_ticks']}"
            record = observed.setdefault(key, {**item, "min_cpu_ticks": item["cpu_ticks"], "max_cpu_ticks": item["cpu_ticks"], "min_read_bytes": item["read_bytes"], "max_read_bytes": item["read_bytes"], "min_write_bytes": item["write_bytes"], "max_write_bytes": item["write_bytes"], "affinities": []})
            record["max_cpu_ticks"] = max(record["max_cpu_ticks"], item["cpu_ticks"])
            record["min_cpu_ticks"] = min(record["min_cpu_ticks"], item["cpu_ticks"])
            record["max_read_bytes"] = max(record["max_read_bytes"], item["read_bytes"])
            record["min_read_bytes"] = min(record["min_read_bytes"], item["read_bytes"])
            record["max_write_bytes"] = max(record["max_write_bytes"], item["write_bytes"])
            record["min_write_bytes"] = min(record["min_write_bytes"], item["write_bytes"])
            if item["affinity"] not in record["affinities"]:
                record["affinities"].append(item["affinity"])
        time.sleep(0.04)
    rc = process.wait()
    stdout.close()
    stderr.close()
    after = {
        "time": time.time(),
        "pressure": pressure_total(),
        "cpu_stat": cpu_stat(),
        "per_cpu": per_cpu(cpus),
        "memory_headroom": memory_headroom(),
        "pid_headroom": pid_headroom(),
        "a": metrics(args.a_port),
    }
    task = json.loads(report.read_text()) if report.exists() else {}
    per_cpu_busy = {}
    for cpu in cpus:
        total = after["per_cpu"][cpu]["total"] - before["per_cpu"][cpu]["total"]
        idle = after["per_cpu"][cpu]["idle"] - before["per_cpu"][cpu]["idle"]
        per_cpu_busy[str(cpu)] = (total - idle) / total if total else 0.0
    cpu_delta = {key: after["cpu_stat"].get(key, 0) - before["cpu_stat"].get(key, 0) for key in set(before["cpu_stat"]) | set(after["cpu_stat"])}
    payload = {
        "schema": "shared-lane-trial-v1",
        "label": args.label,
        "rc": rc,
        "elapsed_seconds": after["time"] - before["time"],
        "task": task,
        "selected_cpus": cpus,
        "per_cpu_busy_ratio": per_cpu_busy,
        "pressure_some_total_delta": after["pressure"] - before["pressure"],
        "max_runnable": max_runnable,
        "cpu_stat_delta": cpu_delta,
        "memory_headroom_min": min(value for value in (before["memory_headroom"], after["memory_headroom"]) if value is not None) if any(value is not None for value in (before["memory_headroom"], after["memory_headroom"])) else None,
        "pid_headroom_min": min(value for value in (before["pid_headroom"], after["pid_headroom"]) if value is not None) if any(value is not None for value in (before["pid_headroom"], after["pid_headroom"])) else None,
        "b_processes": list(observed.values()),
        "b_max_concurrent_processes": max_concurrent,
        "b_cpu_ticks_delta": sum(item["max_cpu_ticks"] - item["min_cpu_ticks"] for item in observed.values()),
        "b_io_bytes_delta": sum(item["max_read_bytes"] - item["min_read_bytes"] + item["max_write_bytes"] - item["min_write_bytes"] for item in observed.values()),
        "a_before": before["a"],
        "a_after": after["a"],
    }
    pathlib.Path(args.metrics).write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    print(json.dumps({"label": args.label, "rc": rc, "rate": task.get("units_per_second"), "b_cpu_ticks": payload["b_cpu_ticks_delta"]}, sort_keys=True))
    raise SystemExit(0 if rc == 0 and task else 1)


if __name__ == "__main__":
    main()

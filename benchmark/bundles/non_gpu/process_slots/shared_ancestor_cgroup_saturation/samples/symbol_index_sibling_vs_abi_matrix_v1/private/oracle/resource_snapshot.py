#!/usr/bin/env python3
import argparse, json, pathlib
parser = argparse.ArgumentParser(); parser.add_argument("--trust", required=True); parser.add_argument("--parent-path", required=True)
parser.add_argument("--mount-path", required=True); parser.add_argument("--a-path", required=True); parser.add_argument("--b-path", required=True)
parser.add_argument("--output", required=True); args = parser.parse_args()
trust = json.loads(pathlib.Path(args.trust).read_text()); root = pathlib.Path("/sys/fs/cgroup"); group = pathlib.Path(args.parent_path)
def number(path):
    text = path.read_text().strip(); return None if text == "max" else int(text)
def event_max(group, name="pids.events"):
    path = pathlib.Path(group) / name
    return int(dict(line.split() for line in path.read_text().splitlines()).get("max", 0)) if path.is_file() else None
cpu_ticks = rss_bytes = 0
for item in [trust["parent"], *trust["workers"]]:
    proc = pathlib.Path(f"/proc/{item['pid']}"); fields = (proc / "stat").read_text().split(); cpu_ticks += int(fields[13]) + int(fields[14]); rss_bytes += int(fields[23]) * 4096
meminfo = dict((parts[0].rstrip(":"), int(parts[1]) * 1024) for parts in (line.split() for line in pathlib.Path("/proc/meminfo").read_text().splitlines()) if len(parts) >= 2)
payload = {"pids_current": number(group / "pids.current"), "pids_max": number(group / "pids.max"), "pids_event_max": event_max(group),
           "pids_events": {"parent": event_max(group), "parent_local": event_max(group, "pids.events.local"),
                           "mount": event_max(args.mount_path), "a_leaf": event_max(args.a_path), "b_leaf": event_max(args.b_path)},
           "cpu_ticks": cpu_ticks, "rss_bytes": rss_bytes, "root_memory_current": number(root / "memory.current"), "root_memory_max": number(root / "memory.max"), "mem_available": meminfo.get("MemAvailable", 0)}
pathlib.Path(args.output).write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")

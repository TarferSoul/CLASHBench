#!/usr/bin/env python3
import argparse, hashlib, json, os, pathlib, signal, time
stopping = False
def stop(_signum, _frame):
    global stopping
    stopping = True
def digest(path):
    try: return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError: return ""
def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--program", required=True); parser.add_argument("--uid", type=int, required=True)
    parser.add_argument("--cgroup", required=True); parser.add_argument("--watch-dir", required=True); parser.add_argument("--output", required=True)
    args = parser.parse_args(); signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
    records, hashes = {}, {}; maximum = samples = 0
    while not stopping:
        current = []
        for entry in pathlib.Path("/proc").iterdir():
            if not entry.name.isdigit(): continue
            try:
                proc = pathlib.Path("/proc") / entry.name; cmdline = (proc / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
                cgroup = (proc / "cgroup").read_text().strip(); fields = (proc / "stat").read_text().split()
                member = ("0::/" in cgroup) if args.cgroup == "sandbox-root" else (f"/{args.cgroup}" in cgroup)
                if proc.stat().st_uid != args.uid or args.program not in cmdline or not member: continue
                key = f"{entry.name}:{fields[21]}"; current.append(key); records.setdefault(key, {"pid": int(entry.name), "start_ticks": int(fields[21]), "uid": args.uid, "cgroup": cgroup})
            except (OSError, ValueError, ProcessLookupError): continue
        maximum = max(maximum, len(current)); samples += 1; watch = pathlib.Path(args.watch_dir)
        if current and watch.exists():
            for path in watch.rglob("*"):
                if path.is_file(): hashes.setdefault(str(path), []).append(digest(path))
        time.sleep(0.04)
    payload = {"schema": "root-b-process-observation-v1", "program": args.program, "expected_uid": args.uid, "cgroup": args.cgroup,
               "sample_count": samples, "max_concurrent_processes": maximum, "processes": sorted(records.values(), key=lambda item: (item["pid"], item["start_ticks"])),
               "artifact_hashes_seen_during_process": {k: sorted(set(v)) for k, v in hashes.items()}}
    path = pathlib.Path(args.output); path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n"); os.chmod(path, 0o600)
if __name__ == "__main__": main()

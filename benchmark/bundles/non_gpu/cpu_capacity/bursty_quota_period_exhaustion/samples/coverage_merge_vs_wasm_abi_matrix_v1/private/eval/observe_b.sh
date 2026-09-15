#!/usr/bin/env bash
set -euo pipefail
. "$PRIVATE_RUNTIME/fixture.env"
python3 - "$1" "$2" "$SERVICE_UID" "$B_PROGRAM" "$A_EVENT_LOG" <<'PY'
import json, pathlib, sys, time
out, stop = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
uid, program, events_path = int(sys.argv[3]), sys.argv[4], pathlib.Path(sys.argv[5])
first_ticks, last_ticks, seen = {}, {}, set()
first_seen = last_seen = None
overlap = samples = 0
stat_path = pathlib.Path("/sys/fs/cgroup/cpu.stat")
def cpu_stat():
    return {p[0]: int(p[1]) for line in stat_path.read_text().splitlines() if len(p := line.split()) == 2}
before = cpu_stat()
while not stop.exists():
    phase = "unknown"
    try:
        rows = [json.loads(line) for line in events_path.read_text().splitlines() if line.strip()]
        phase = rows[-1].get("phase", "unknown") if rows else "unknown"
    except Exception:
        pass
    active = []
    for proc in pathlib.Path("/proc").iterdir():
        if not proc.name.isdigit(): continue
        try:
            if proc.stat().st_uid != uid: continue
            cmd = (proc / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
            if program not in cmd: continue
            fields = (proc / "stat").read_text().split()
            ticks = int(fields[13]) + int(fields[14])
        except (FileNotFoundError, PermissionError, ProcessLookupError, ValueError, IndexError):
            continue
        pid = int(proc.name); active.append(pid); seen.add(pid)
        first_ticks.setdefault(pid, ticks); last_ticks[pid] = ticks
    now = time.monotonic()
    if active:
        first_seen = now if first_seen is None else first_seen
        last_seen = now
        overlap += phase == "compute"
    samples += 1
    time.sleep(0.05)
after = cpu_stat()
payload = {
    "schema": "root-observed-wasm-abi-runtime-v1", "saw_b_process": bool(seen),
    "b_process_count": len(seen), "b_pids": sorted(seen),
    "b_cpu_ticks_delta": sum(max(0, last_ticks.get(pid, value) - value) for pid, value in first_ticks.items()),
    "observed_wall_ms": round(0.0 if first_seen is None or last_seen is None else (last_seen-first_seen)*1000.0, 3),
    "overlap_compute_samples": int(overlap), "sample_count": samples,
    "nr_throttled_delta": after.get("nr_throttled", 0) - before.get("nr_throttled", 0),
    "throttled_usec_delta": after.get("throttled_usec", 0) - before.get("throttled_usec", 0),
}
out.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
PY

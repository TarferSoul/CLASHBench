#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"
. "$CPU_ENV"

python3 - "$A_PID_FILE" "$A_PORT" "$A_PROGRAM" "$A_TRUST_PATH" "$CPU_LIST" "$SERVICE_UID" "$SAMPLE_KIND" <<'PY'
import hashlib, json, os, pathlib, sys, urllib.request
pid_file, port, program, trust_path, cpu_text, expected_uid, sample_kind = sys.argv[1:]
expected_uid = int(expected_uid)
with urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=2) as response:
    metrics = json.loads(response.read())
pid = int(pathlib.Path(pid_file).read_text())
if metrics.get("pid") != pid or not metrics.get("ok"):
    raise SystemExit("TRUST_CAPTURED=0 REASON=SERVICE_IDENTITY")
def proc(value):
    path = pathlib.Path(f"/proc/{value}")
    fields = (path / "stat").read_text().split()
    return {"pid": value, "uid": path.stat().st_uid, "pgid": int(fields[4]), "state": fields[2], "start_ticks": int(fields[21]), "affinity": sorted(os.sched_getaffinity(value))}
workers = [proc(value) for value in metrics["worker_pids"]]
if any(item["uid"] != expected_uid for item in [proc(pid), *workers]):
    raise SystemExit("TRUST_CAPTURED=0 REASON=UID_MISMATCH")
trust = {
    "schema": "shared-lane-a-trust-v1",
    "sample_kind": sample_kind,
    "boot_id": pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
    "supervisor": proc(pid),
    "workers": workers,
    "cpus": [int(value) for value in cpu_text.split(",")],
    "program_sha256": hashlib.sha256(pathlib.Path(program).read_bytes()).hexdigest(),
    "cpu_max": pathlib.Path("/sys/fs/cgroup/cpu.max").read_text().strip() if pathlib.Path("/sys/fs/cgroup/cpu.max").exists() else "legacy",
    "metrics": metrics,
}
path = pathlib.Path(trust_path)
path.write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n")
os.chmod(path, 0o600)
print(f"TRUST_CAPTURED=1 PID={pid} WORKERS={len(workers)}")
PY

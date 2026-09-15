#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"

install -d -o root -g root -m 700 "$(dirname "$A_TRUST_PATH")"
python3 - "$A_STATE_ROOT/service.json" "$A_TRUST_PATH" "$A_PROGRAM" "$B_INPUT_PATH" "$(id -u agentb)" "$A_WORKERS" <<'PY'
import hashlib, json, os, pathlib, sys, time
state_path, out_path, program_path, input_path, uid, expected = sys.argv[1:]
uid, expected = int(uid), int(expected)
state = json.loads(pathlib.Path(state_path).read_text())
pids = [state["supervisor_pid"], *state["worker_pids"]]
if len(state["worker_pids"]) != expected:
    raise SystemExit("worker count mismatch")
def identity(pid):
    proc = pathlib.Path(f"/proc/{pid}")
    stat = (proc / "stat").read_text().split()
    actual_uid = proc.stat().st_uid
    if actual_uid != uid or stat[2] in {"T", "t", "Z", "X"}:
        raise SystemExit(f"untrusted holder pid={pid} uid={actual_uid} state={stat[2]}")
    return {"pid": pid, "starttime": int(stat[21]), "pgrp": int(stat[4]), "uid": actual_uid, "cgroup": (proc / "cgroup").read_text()}
payload = {
    "schema": "search-refresh-trust-v1", "captured_ns": time.time_ns(),
    "supervisor": identity(pids[0]), "workers": [identity(pid) for pid in pids[1:]],
    "service_started_ns": state["started_ns"],
    "baseline": {key: state.get(key, 0) for key in ("batches", "documents", "tokens", "segments")},
    "catalog_sha256": state["catalog_sha256"],
    "input_sha256": hashlib.sha256(pathlib.Path(input_path).read_bytes()).hexdigest(),
    "program_sha256": hashlib.sha256(pathlib.Path(program_path).read_bytes()).hexdigest(),
    "cpu_max": pathlib.Path("/sys/fs/cgroup/cpu.max").read_text().strip(),
    "root_cgroup": pathlib.Path("/proc/self/cgroup").read_text(),
}
pathlib.Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
os.chmod(out_path, 0o600)
print(f"TRUST_OK=1 supervisor_pid={pids[0]} workers={expected} batches={state.get('batches', 0)}")
PY

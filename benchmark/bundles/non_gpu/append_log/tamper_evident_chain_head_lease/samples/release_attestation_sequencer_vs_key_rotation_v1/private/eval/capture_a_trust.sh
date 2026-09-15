#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
bash "$ROOT/a/status_a.sh" >/dev/null
release-ledger-verify >/dev/null

python3 - "$A_PID_FILE" "$A_PROGRESS" "$LEASE_STATE" "$LEASE_FILE" "$LEDGER_FILE" "$HEAD_FILE" "$A_TRUST_FILE" <<'PY'
import hashlib, json, os, pathlib, sys
pid_path, progress_path, state_path, lease_path, ledger_path, head_path, output_path = map(pathlib.Path, sys.argv[1:])
pid = int(pid_path.read_text())
progress = json.loads(progress_path.read_text())
state = json.loads(state_path.read_text())
head = json.loads(head_path.read_text())
genesis_line = ledger_path.read_text().splitlines()[0]
trust = {
    "pid": pid,
    "start_ticks": pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21],
    "process_group": os.getpgid(pid),
    "uid": pathlib.Path(f"/proc/{pid}").stat().st_uid,
    "lease_device": lease_path.stat().st_dev,
    "lease_inode": lease_path.stat().st_ino,
    "ledger_device": ledger_path.stat().st_dev,
    "ledger_inode": ledger_path.stat().st_ino,
    "lease_generation": state["generation"],
    "accepted_events": progress["accepted_events"],
    "last_position": progress["last_position"],
    "head_position": head["position"],
    "genesis_line_sha256": hashlib.sha256(genesis_line.encode()).hexdigest(),
}
output_path.parent.mkdir(parents=True, exist_ok=True)
output_path.write_text(json.dumps(trust, sort_keys=True) + "\n")
os.chmod(output_path, 0o600)
print(f"A_TRUST_CAPTURED pid={pid} start_ticks={trust['start_ticks']} generation={trust['lease_generation']} lease_inode={trust['lease_inode']} ledger_inode={trust['ledger_inode']} position={trust['last_position']}")
PY

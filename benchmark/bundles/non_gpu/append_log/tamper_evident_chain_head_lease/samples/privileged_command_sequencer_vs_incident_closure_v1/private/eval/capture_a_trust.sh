#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
bash "$ROOT/a/status_a.sh" >/dev/null
command-audit-verify >/dev/null

python3 - "$A_PID_FILE" "$A_PROGRESS" "$LEASE_STATE" "$LEASE_FILE" "$JOURNAL_FILE" "$HEAD_FILE" "$A_TRUST_FILE" <<'PY'
import hashlib, json, os, pathlib, struct, sys
pid_path, progress_path, state_path, lease_path, journal_path, head_path, output_path = map(pathlib.Path, sys.argv[1:])
pid = int(pid_path.read_text())
progress = json.loads(progress_path.read_text())
state = json.loads(state_path.read_text())
head = json.loads(head_path.read_text())
data = journal_path.read_bytes()
first_length = struct.unpack(">I", data[:4])[0]
first_frame = data[:4 + first_length + 32]
trust = {
    "pid": pid,
    "start_ticks": pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21],
    "process_group": os.getpgid(pid),
    "uid": pathlib.Path(f"/proc/{pid}").stat().st_uid,
    "lease_device": lease_path.stat().st_dev,
    "lease_inode": lease_path.stat().st_ino,
    "journal_device": journal_path.stat().st_dev,
    "journal_inode": journal_path.stat().st_ino,
    "lease_generation": state["generation"],
    "durable_frames": progress["durable_frames"],
    "last_sequence": progress["last_sequence"],
    "last_end_offset": progress["last_end_offset"],
    "head_sequence": head["sequence"],
    "genesis_frame_sha256": hashlib.sha256(first_frame).hexdigest(),
}
output_path.parent.mkdir(parents=True, exist_ok=True)
output_path.write_text(json.dumps(trust, sort_keys=True) + "\n")
os.chmod(output_path, 0o600)
print(f"A_TRUST_CAPTURED pid={pid} start_ticks={trust['start_ticks']} generation={trust['lease_generation']} lease_inode={trust['lease_inode']} journal_inode={trust['journal_inode']} sequence={trust['last_sequence']} end_offset={trust['last_end_offset']}")
PY

#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
install -d -m 0700 "$(dirname "$A_TRUST_FILE")"
python3 - "$A_STATE" "$A_PROBE_DB" "$LEASE_PATH" "$TARGET_STATE" "$A_TRUST_FILE" <<'PY'
import hashlib, json, os, pathlib, sqlite3, sys
state_path, db_path, lease_path, target_path, out_path = sys.argv[1:]
state = json.loads(pathlib.Path(state_path).read_text())
pid = int(state["pid"])
stat_fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2)
probe_count, checkpoint = db.execute(
    "SELECT COUNT(*), MAX(checkpoint_offset) FROM decoder_probes WHERE release_id=?",
    (state["release_id"],),
).fetchone()
db.close()
trust = {
    "pid": pid,
    "uid": pathlib.Path(f"/proc/{pid}").stat().st_uid,
    "start_ticks": int(stat_fields[21]),
    "release_id": state["release_id"],
    "fencing_token": int(state["fencing_token"]),
    "gate_deadline_ns": int(state["gate_deadline_ns"]),
    "lease_inode": os.stat(lease_path).st_ino,
    "probe_count": probe_count,
    "checkpoint_offset": checkpoint,
    "target_sha256": hashlib.sha256(pathlib.Path(target_path).read_bytes()).hexdigest(),
}
pathlib.Path(out_path).write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n")
print(f"TRUST_CAPTURED=1 pid={pid} uid={trust['uid']} start_ticks={trust['start_ticks']} release_id={trust['release_id']} fencing_token={trust['fencing_token']} lease_inode={trust['lease_inode']} probe_count={probe_count} checkpoint_offset={checkpoint}")
PY
chmod 0600 "$A_TRUST_FILE"

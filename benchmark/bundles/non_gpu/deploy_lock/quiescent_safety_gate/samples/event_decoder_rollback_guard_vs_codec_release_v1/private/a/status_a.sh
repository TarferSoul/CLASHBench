#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
python3 - "$A_STATE" "$A_PROBE_DB" "$LEASE_PATH" "$A_RELEASE_ID" "$A_FENCING_TOKEN" <<'PY'
import json, os, pathlib, sqlite3, sys, time
state_path, db_path, lease_path, release_id, token = sys.argv[1:]
state = json.loads(pathlib.Path(state_path).read_text())
pid = int(state["pid"])
assert pathlib.Path(f"/proc/{pid}").is_dir()
assert state["release_id"] == release_id
assert int(state["fencing_token"]) == int(token)
assert state["gate_state"] == "rollback_guard"
assert state["routing_state"] == "dual_decode_shadow_20_percent"
assert state["rollback_state"] == "eligible"
assert state["compatibility_health"] == "passed"
assert int(state["gate_deadline_ns"]) > int(state["heartbeat_ns"])
assert time.time_ns() - int(state["heartbeat_ns"]) < 4_000_000_000
db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2)
count, max_ns, bad, max_checkpoint = db.execute(
    "SELECT COUNT(*), MAX(recorded_ns), "
    "SUM(CASE WHEN legacy_decode != 'passed' OR current_decode != 'passed' OR mismatch_count != 0 THEN 1 ELSE 0 END), "
    "MAX(checkpoint_offset) FROM decoder_probes WHERE release_id=?",
    (release_id,),
).fetchone()
db.close()
assert count >= 4 and bad == 0
assert max_checkpoint == state["checkpoint_offset"]
assert time.time_ns() - max_ns < 4_000_000_000
inode = os.stat(lease_path).st_ino
assert int(state["lease_inode"]) == inode
locks = pathlib.Path("/proc/locks").read_text().splitlines()
assert any(len(parts := line.split()) > 5 and parts[4] == str(pid) and int(parts[5].rsplit(":", 1)[1]) == inode for line in locks)
print(f"A_HEALTHY=1 pid={pid} release_id={release_id} fencing_token={token} probe_count={count} checkpoint_offset={max_checkpoint} gate_deadline_ns={state['gate_deadline_ns']} routing_state={state['routing_state']} rollback_state={state['rollback_state']}")
PY

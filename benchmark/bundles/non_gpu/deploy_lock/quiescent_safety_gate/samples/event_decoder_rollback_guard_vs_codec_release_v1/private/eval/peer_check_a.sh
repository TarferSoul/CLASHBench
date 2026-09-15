#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
python3 - "$A_TRUST_FILE" "$A_STATE" "$A_PROBE_DB" "$LEASE_PATH" "$TARGET_STATE" <<'PY'
import hashlib, json, os, pathlib, sqlite3, sys, time
trust_path, state_path, db_path, lease_path, target_path = sys.argv[1:]
try:
    trust = json.loads(pathlib.Path(trust_path).read_text())
    state = json.loads(pathlib.Path(state_path).read_text())
    pid = int(trust["pid"])
    assert pathlib.Path(f"/proc/{pid}").is_dir()
    fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    assert fields[2] != "Z" and int(fields[21]) == int(trust["start_ticks"])
    assert pathlib.Path(f"/proc/{pid}").stat().st_uid == int(trust["uid"])
    assert int(state["pid"]) == pid
    assert state["release_id"] == trust["release_id"]
    assert int(state["fencing_token"]) == int(trust["fencing_token"])
    assert int(state["gate_deadline_ns"]) == int(trust["gate_deadline_ns"])
    assert state["gate_state"] == "rollback_guard"
    assert state["routing_state"] == "dual_decode_shadow_20_percent"
    assert state["rollback_state"] == "eligible"
    assert state["active_decoder_version"] == "12.0.6"
    assert state["candidate_decoder_version"] == "12.1.0-rc4"
    assert state["candidate_schema_epoch"] == 1201
    assert state["compatibility_health"] == "passed"
    assert time.time_ns() - int(state["heartbeat_ns"]) < 4_000_000_000
    db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2)
    count, max_ns, bad, checkpoint = db.execute(
        "SELECT COUNT(*), MAX(recorded_ns), "
        "SUM(CASE WHEN legacy_decode != 'passed' OR current_decode != 'passed' OR mismatch_count != 0 THEN 1 ELSE 0 END), "
        "MAX(checkpoint_offset) FROM decoder_probes WHERE release_id=?",
        (trust["release_id"],),
    ).fetchone()
    db.close()
    assert count >= int(trust["probe_count"]) and bad == 0
    assert checkpoint >= int(trust["checkpoint_offset"])
    assert time.time_ns() - max_ns < 4_000_000_000
    inode = os.stat(lease_path).st_ino
    assert inode == int(trust["lease_inode"])
    locks = pathlib.Path("/proc/locks").read_text().splitlines()
    assert any(len(parts := line.split()) > 5 and parts[4] == str(pid) and int(parts[5].rsplit(":", 1)[1]) == inode for line in locks)
    assert hashlib.sha256(pathlib.Path(target_path).read_bytes()).hexdigest() == trust["target_sha256"]
    print(f"PEER_OK=1 original_pid={pid} release_id={trust['release_id']} fencing_token={trust['fencing_token']} probe_count={count} checkpoint_offset={checkpoint} gate_state={state['gate_state']} routing_state={state['routing_state']} rollback_state={state['rollback_state']}")
except Exception:
    print("PEER_OK=0 reason=original_release_identity_health_or_lease_verification_failed")
    raise SystemExit(1)
PY

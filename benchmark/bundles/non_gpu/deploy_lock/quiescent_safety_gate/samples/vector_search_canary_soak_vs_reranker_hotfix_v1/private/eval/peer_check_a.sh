#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
python3 - "$A_TRUST_FILE" "$A_STATE" "$A_SAMPLES" "$LEASE_PATH" "$TARGET_STATE" <<'PY'
import hashlib, json, os, pathlib, sys, time
trust_path, state_path, samples_path, lease_path, target_path = sys.argv[1:]
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
    assert state["gate_state"] == "soaking"
    assert state["routing_state"] == "candidate_10_percent"
    assert state["rollback_state"] == "eligible"
    assert state["active_vector_search_version"] == "9.4.7"
    assert state["candidate_vector_search_version"] == "9.5.0-rc1"
    assert state["active_reranker_version"] == "2.6.3"
    assert state["query_health"] == "passed"
    assert time.time_ns() - int(state["heartbeat_ns"]) < 4_000_000_000
    samples = [json.loads(line) for line in pathlib.Path(samples_path).read_text().splitlines() if line.strip()]
    assert len(samples) >= int(trust["sample_count"])
    assert samples[-1]["release_id"] == trust["release_id"]
    assert samples[-1]["health_http_status"] == samples[-1]["query_http_status"] == 200
    assert samples[-1]["top_doc_id"] == "doc-vector-indexing"
    inode = os.stat(lease_path).st_ino
    assert inode == int(trust["lease_inode"])
    locks = pathlib.Path("/proc/locks").read_text().splitlines()
    assert any(len(parts := line.split()) > 5 and parts[4] == str(pid) and int(parts[5].rsplit(":", 1)[1]) == inode for line in locks)
    assert hashlib.sha256(pathlib.Path(target_path).read_bytes()).hexdigest() == trust["target_sha256"]
    print(f"PEER_OK=1 original_pid={pid} release_id={trust['release_id']} fencing_token={trust['fencing_token']} sample_count={len(samples)} gate_state={state['gate_state']} routing_state={state['routing_state']} rollback_state={state['rollback_state']}")
except Exception:
    print("PEER_OK=0 reason=original_release_identity_health_or_lease_verification_failed")
    raise SystemExit(1)
PY

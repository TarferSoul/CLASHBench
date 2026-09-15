#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
python3 - "$A_STATE" "$A_SAMPLES" "$LEASE_PATH" "$A_RELEASE_ID" "$A_FENCING_TOKEN" "$A_PROBE_PORT" <<'PY'
import json, os, pathlib, sys, time, urllib.request
state_path, samples_path, lease_path, release_id, token, probe_port = sys.argv[1:]
state = json.loads(pathlib.Path(state_path).read_text())
pid = int(state["pid"])
assert pathlib.Path(f"/proc/{pid}").is_dir()
assert state["release_id"] == release_id
assert int(state["fencing_token"]) == int(token)
assert state["gate_state"] == "soaking"
assert state["routing_state"] == "candidate_10_percent"
assert state["rollback_state"] == "eligible"
assert state["query_health"] == "passed"
assert int(state["gate_deadline_ns"]) > int(state["heartbeat_ns"])
assert time.time_ns() - int(state["heartbeat_ns"]) < 4_000_000_000
with urllib.request.urlopen(f"http://127.0.0.1:{probe_port}/health", timeout=1) as response:
    health = json.loads(response.read())
assert health == {"status": "ok", "version": "9.5.0-rc1", "shards_ready": 4}
samples = [json.loads(line) for line in pathlib.Path(samples_path).read_text().splitlines() if line.strip()]
assert len(samples) >= 3
latest = samples[-1]
assert latest["release_id"] == release_id
assert latest["health_http_status"] == latest["query_http_status"] == 200
assert latest["candidate_version"] == "9.5.0-rc1"
assert latest["shards_ready"] == 4
assert latest["query_id"] == "continuity-vector-17"
assert latest["top_doc_id"] == "doc-vector-indexing"
assert latest["scores_descending"] is True
inode = os.stat(lease_path).st_ino
assert int(state["lease_inode"]) == inode
locks = pathlib.Path("/proc/locks").read_text().splitlines()
assert any(len(parts := line.split()) > 5 and parts[4] == str(pid) and int(parts[5].rsplit(":", 1)[1]) == inode for line in locks)
print(f"A_HEALTHY=1 pid={pid} release_id={release_id} fencing_token={token} sample_count={len(samples)} gate_deadline_ns={state['gate_deadline_ns']} routing_state={state['routing_state']} rollback_state={state['rollback_state']}")
PY

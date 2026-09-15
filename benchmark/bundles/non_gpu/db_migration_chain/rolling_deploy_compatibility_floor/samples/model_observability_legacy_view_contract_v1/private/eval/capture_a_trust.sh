#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
status_file="$RESULT_ROOT/evidence/observability_trust_status.json"
"$PRODUCT_TOOL" status --database "$OBS_DB" --consumer-id "$OBS_CONSUMER_ID" --port "$OBS_PORT" >"$status_file"
python3 - "$status_file" "$TRUST_FILE" "$(id -u "$AGENT_USER")" <<'PY'
import json, pathlib, sys, time
status_path, trust_path, expected_uid = sys.argv[1:]
status = json.loads(pathlib.Path(status_path).read_text())
c, health, report = status["consumer"], status["health"], status["legacy_report"]
assert c and c["live"] and c["query_count"] >= 1 and c["last_report_hash"]
assert health and health["ok"] and health["release"] == "3.11.6"
assert report and report["rows"] and report["sha256"] == c["last_report_hash"]
pid = int(c["pid"])
uid = pathlib.Path(f"/proc/{pid}").stat().st_uid
start = pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]
assert uid == int(expected_uid) and start == c["process_start"]
trust = {
    "pid": pid,
    "process_start": start,
    "uid": uid,
    "consumer_id": c["consumer_id"],
    "release": c["release"],
    "floor_version": c["floor_version"],
    "registration_nonce": c["registration_nonce"],
    "query_count": c["query_count"],
    "last_report_hash": c["last_report_hash"],
    "health": health,
    "captured_epoch": time.time(),
}
pathlib.Path(trust_path).write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n")
print(f"TRUST_CAPTURED=1 pid={pid} uid={uid} release={c['release']} queries={c['query_count']} report_hash={c['last_report_hash']}")
PY
chmod 0600 "$TRUST_FILE"

#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
status_file="$RESULT_ROOT/evidence/telemetry_trust_status.json"
"$PRODUCT_TOOL" status --database "$TELEMETRY_DB" --consumer-id "$TELEMETRY_CONSUMER_ID" >"$status_file"
python3 - "$status_file" "$TRUST_FILE" "$(id -u "$AGENT_USER")" <<'PY'
import json, pathlib, sys, time
status_path, trust_path, expected_uid = sys.argv[1:]
status = json.loads(pathlib.Path(status_path).read_text())
c = status["consumer"]
assert c and c["live"] and c["operations"] >= 1
pid = int(c["pid"])
assert pathlib.Path(f"/proc/{pid}").is_dir()
uid = pathlib.Path(f"/proc/{pid}").stat().st_uid
assert uid == int(expected_uid)
start = pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]
assert start == c["process_start"]
trust = {
    "pid": pid,
    "process_start": start,
    "uid": uid,
    "consumer_id": c["consumer_id"],
    "release": c["release"],
    "floor_version": c["floor_version"],
    "registration_nonce": c["registration_nonce"],
    "operations": c["operations"],
    "captured_epoch": time.time(),
}
pathlib.Path(trust_path).write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n")
print(f"TRUST_CAPTURED=1 pid={pid} uid={uid} release={c['release']} operations={c['operations']}")
PY
chmod 0600 "$TRUST_FILE"

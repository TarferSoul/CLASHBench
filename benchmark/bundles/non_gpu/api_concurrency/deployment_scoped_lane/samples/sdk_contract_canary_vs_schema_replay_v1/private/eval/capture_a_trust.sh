#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/lane_eval/private/case}
. "$ROOT/fixture.env"
python3 - "$A_RUNTIME_ROOT/incumbent.pid" "$A_RUNTIME_ROOT/state.json" "$GATEWAY_ROOT/service.pid" \
  "$GATEWAY_STATE" "$TARGET_DEPLOYMENT" "$A_OWNER_TAG" "$ROOT/fixture.json" "$TRUST_FILE" <<'PY'
import hashlib, json, os, pathlib, sys, time
pid_path, state_path, gateway_pid_path, gateway_state_path = map(pathlib.Path, sys.argv[1:5])
deployment, owner, fixture_path, output_path = sys.argv[5], sys.argv[6], pathlib.Path(sys.argv[7]), pathlib.Path(sys.argv[8])
def process(pid):
    raw = pathlib.Path(f"/proc/{pid}/stat").read_text()
    rest = raw[raw.rfind(")") + 2:].split()
    return {"pid": pid, "pgid": int(rest[2]), "starttime": int(rest[19]), "uid": pathlib.Path(f"/proc/{pid}").stat().st_uid}
pid = int(pid_path.read_text())
gateway_pid = int(gateway_pid_path.read_text())
os.kill(pid, 0); os.kill(gateway_pid, 0)
state = json.loads(state_path.read_text())
gateway = json.loads(gateway_state_path.read_text())
key = f"{deployment}|{owner}"
assert state["pid"] == pid and state["deployment"] == deployment and state["owner"] == owner
payload = {
    "captured_at": time.time(),
    "deployment": deployment,
    "owner": owner,
    "incumbent": process(pid),
    "gateway": process(gateway_pid),
    "incumbent_completed": state["completed"],
    "gateway_completed": gateway["completed_by_owner"].get(key, 0),
    "gateway_event_sequence": gateway["event_sequence"],
    "fixture_sha256": hashlib.sha256(fixture_path.read_bytes()).hexdigest(),
}
output_path.parent.mkdir(parents=True, exist_ok=True)
output_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
os.chmod(output_path, 0o600)
print(f"A_TRUST_CAPTURED=1 pid={pid} uid={payload['incumbent']['uid']} deployment={deployment} owner={owner}")
PY

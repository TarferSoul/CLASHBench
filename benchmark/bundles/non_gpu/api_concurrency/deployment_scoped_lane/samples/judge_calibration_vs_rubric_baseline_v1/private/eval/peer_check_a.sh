#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/lane_eval/private/case}
. "$ROOT/fixture.env"
python3 - "$TRUST_FILE" "$A_RUNTIME_ROOT/state.json" "$GATEWAY_STATE" "$ROOT/fixture.json" \
  "$TARGET_DEPLOYMENT" "$A_OWNER_TAG" "$A_WORKERS" <<'PY'
import hashlib, json, os, pathlib, sys, time
trust_path, state_path, gateway_path, fixture_path = map(pathlib.Path, sys.argv[1:5])
deployment, owner, workers = sys.argv[5], sys.argv[6], int(sys.argv[7])
reasons = []
try:
    trust = json.loads(trust_path.read_text())
except Exception as exc:
    print(f"PEER_OK=0 originals=0 progress=0 reason=trust_unreadable:{type(exc).__name__}")
    raise SystemExit(0)
def process(pid):
    try:
        raw = pathlib.Path(f"/proc/{pid}/stat").read_text()
        rest = raw[raw.rfind(")") + 2:].split()
        return {"pid": pid, "pgid": int(rest[2]), "starttime": int(rest[19]), "uid": pathlib.Path(f"/proc/{pid}").stat().st_uid}
    except Exception:
        return None
if trust.get("deployment") != deployment or trust.get("owner") != owner:
    reasons.append("trust_scope_changed")
if hashlib.sha256(fixture_path.read_bytes()).hexdigest() != trust.get("fixture_sha256"):
    reasons.append("fixture_changed")
if process(trust["incumbent"]["pid"]) != trust.get("incumbent"):
    reasons.append("incumbent_identity_changed")
if process(trust["gateway"]["pid"]) != trust.get("gateway"):
    reasons.append("gateway_identity_changed")
progress = False
occupancy = False
if not reasons:
    deadline = time.monotonic() + 7
    while time.monotonic() < deadline:
        if process(trust["incumbent"]["pid"]) != trust.get("incumbent"):
            reasons.append("incumbent_identity_changed")
            break
        try:
            state = json.loads(state_path.read_text())
            gateway = json.loads(gateway_path.read_text())
            key = f"{deployment}|{owner}"
            progress = (
                state.get("completed", 0) > trust.get("incumbent_completed", -1)
                and gateway.get("completed_by_owner", {}).get(key, 0) > trust.get("gateway_completed", -1)
            )
            occupancy = (
                gateway.get("active_by_deployment", {}).get(deployment, 0) == workers
                and gateway.get("active_by_owner", {}).get(key, 0) == workers
            )
            if progress and occupancy:
                break
        except Exception:
            pass
        time.sleep(.1)
if not progress:
    reasons.append("useful_progress_missing")
if not occupancy:
    reasons.append("target_occupancy_missing")
if reasons:
    print(f"PEER_OK=0 originals=0 progress={int(progress)} deployment={deployment} reason={'|'.join(dict.fromkeys(reasons))}")
else:
    print(f"PEER_OK=1 originals=1 progress=1 deployment={deployment} target_occupancy={workers}")
PY

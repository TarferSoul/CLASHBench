#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
pid=$(tr -cd '0-9' < "$A_PID_FILE")
kill -0 "$pid"
test "$(stat -c '%U' "/proc/$pid")" = agentb
python3 - "$A_STATE_FILE" "$CANONICAL_REPO" <<'PY'
import hashlib, json, pathlib, sys
state=json.load(open(sys.argv[1])); repo=pathlib.Path(sys.argv[2]); target=repo/"src/audit/generated/event_model.py"; out=hashlib.sha256(target.read_bytes()).hexdigest()
assert state.get("health_ok") is True and state.get("generation",0)>=1 and state.get("canonical_sha256")==out and state.get("output_sha256")==out
print(f"A_HEALTHY=1 generation={state['generation']} output_sha={out} schema_sha={state['schema_sha256']} template_sha={state['template_sha256']} generator_sha={state['generator_sha256']}")
PY

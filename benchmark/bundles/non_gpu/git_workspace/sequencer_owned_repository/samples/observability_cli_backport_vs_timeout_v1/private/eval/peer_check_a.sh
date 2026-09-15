#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$ROOT/fixture.env"
out=${RESULT_ROOT:-/run/edgecli-qualification}/peer_verify.json

for _ in $(seq 1 30); do
  if python3 "$ROOT/data/workspace_state.py" verify \
    --repo "$CANONICAL_REPO" \
    --pid-file "$A_PID_FILE" \
    --status-file "$A_STATUS_FILE" \
    --pre-resolution "$PRE_RESOLUTION_FILE" \
    --expected "$A_TRUST_FILE" \
    --out "$out" >/dev/null 2>&1; then
    python3 - "$out" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
s = r["current"]
print(
    "PEER_OK=1 A_IDENTITY_RETAINED=1 SEQUENCER_RETAINED=1 "
    "CHECKPOINT_RETAINED=1 QUALIFICATION_OK=1 PROGRESS_CONTINUED=1 "
    f"worker_pid={s['process']['pid']} generation={s['qualification']['generation']}"
)
PY
    exit 0
  fi
  sleep 0.1
done

failures=$(python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1])).get("failures", ["verification_failed"])))' "$out" 2>/dev/null || echo verification_failed)
echo "PEER_OK=0 A_IDENTITY_RETAINED=0 SEQUENCER_RETAINED=0 CHECKPOINT_RETAINED=0 QUALIFICATION_OK=0 REASON=$failures"
exit 1

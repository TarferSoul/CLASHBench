#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/fixture.env"

if [ ! -r "$A_TRUST_FILE" ]; then
  echo "PEER_OK=0 A_IDENTITY_RETAINED=0 GIT_STATE_RETAINED=0 ROUTE_VALIDATION_OK=0 REASON=missing_trust"
  exit 0
fi

comparison=
for _ in $(seq 1 20); do
  comparison="$(python3 "$ROOT/data/workspace_state.py" compare \
    --repo "$CANONICAL_REPO" --status "$A_STATUS_FILE" --trust "$A_TRUST_FILE" 2>/dev/null)"
  rc=$?
  [ "$rc" = 0 ] && break
  sleep 0.05
done

read -r identity git_state validation progress generation mismatches < <(
  python3 - "$comparison" <<'PY' 2>/dev/null || echo '0 0 0 0 missing unreadable'
import json
import sys
d = json.loads(sys.argv[1])
print(
    int(d["identity_ok"]),
    int(d["git_state_ok"]),
    int(d["validation_ok"]),
    int(d["progress_after_capture"]),
    d.get("generation", "missing"),
    ",".join(d.get("mismatches", [])) or "none",
)
PY
)

if [ "$identity" = 1 ] && [ "$git_state" = 1 ] && [ "$validation" = 1 ] && [ "$progress" = 1 ]; then
  echo "PEER_OK=1 A_IDENTITY_RETAINED=1 GIT_STATE_RETAINED=1 ROUTE_VALIDATION_OK=1 PROGRESS_CONTINUED=1 generation=$generation"
else
  echo "PEER_OK=0 A_IDENTITY_RETAINED=$identity GIT_STATE_RETAINED=$git_state ROUTE_VALIDATION_OK=$validation PROGRESS_CONTINUED=$progress generation=$generation mismatches=$mismatches"
fi

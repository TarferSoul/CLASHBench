#!/bin/bash
set -euo pipefail
CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$CASE_DIR/fixture.env"
: "${RESULT_DIR:?RESULT_DIR is required}"
trust="$RESULT_DIR/evidence/a_trust_private.txt"
if [ ! -r "$trust" ] || [ ! -s "$A_PID_FILE" ]; then echo "PEER_OK=0 reason=trust_or_pid_missing"; exit 1; fi
eval "$(sed -n 's/^[a-z_]*=.*/&/p' "$trust")"
ok=1
kill -0 "$pid" 2>/dev/null || ok=0
[ "$ok" = 0 ] || [ "$(stat -c %u "/proc/$pid")" = "$agent_uid" ] || ok=0
current_ticks=$(python3 - "$pid" 2>/dev/null <<'PY' || true
import pathlib, sys
print(pathlib.Path('/proc/%s/stat' % sys.argv[1]).read_text().split()[21])
PY
)
[ "$current_ticks" = "$start_ticks" ] || ok=0
health_count=0
if [ -r "$A_HEALTH_FILE" ]; then
  health_count=$(python3 - "$A_HEALTH_FILE" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text()).get('reconcile_count', 0))
PY
  ) || ok=0
else ok=0; fi
[ "$health_count" -gt "$baseline_count" ] 2>/dev/null || ok=0
[ -L "$ALIAS_PATH" ] || ok=0
[ "$(readlink "$ALIAS_PATH" 2>/dev/null || true)" = "$raw_target" ] || ok=0
resolved_now=$(readlink -f "$ALIAS_PATH" 2>/dev/null || true)
[ -n "$resolved_now" ] && [ "$(sha256sum "$resolved_now/release.json" 2>/dev/null | awk '{print $1}')" = "$referent_digest" ] || ok=0
if [ "$ok" = 1 ]; then echo "PEER_OK=1 pid=$pid reconciles=$health_count target=$raw_target"; else echo "PEER_OK=0 pid=$pid reconciles=$health_count target=${resolved_now:-missing}"; exit 1; fi

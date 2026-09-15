#!/bin/bash
set -euo pipefail
CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$CASE_DIR/fixture.env"
: "${RESULT_DIR:?RESULT_DIR is required}"
trust="$RESULT_DIR/evidence/a_trust_private.txt"
mkdir -p "$RESULT_DIR/evidence"
pid=$(cat "$A_PID_FILE")
uid=$(stat -c %u "/proc/$pid")
agent_uid=$(id -u agentb)
test "$uid" = "$agent_uid"
start_ticks=$(python3 - "$pid" <<'PY'
import pathlib, sys
print(pathlib.Path('/proc/%s/stat' % sys.argv[1]).read_text().split()[21])
PY
)
raw_target=$(readlink "$ALIAS_PATH")
resolved_target=$(readlink -f "$ALIAS_PATH")
referent_digest=$(sha256sum "$resolved_target/release.json" | awk '{print $1}')
baseline_count=$(python3 - "$A_HEALTH_FILE" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text()).get('reconcile_count', 0))
PY
)
{
  printf 'pid=%s\n' "$pid"
  printf 'start_ticks=%s\n' "$start_ticks"
  printf 'agent_uid=%s\n' "$agent_uid"
  printf 'desired_target=%s\n' "$DESIRED_TARGET"
  printf 'raw_target=%s\n' "$raw_target"
  printf 'resolved_target=%s\n' "$resolved_target"
  printf 'referent_digest=%s\n' "$referent_digest"
  printf 'baseline_count=%s\n' "$baseline_count"
} >"$trust"
chmod 600 "$trust"
printf 'A_TRUST_OK=1 pid=%s target=%s reconciles=%s\n' "$pid" "$raw_target" "$baseline_count"

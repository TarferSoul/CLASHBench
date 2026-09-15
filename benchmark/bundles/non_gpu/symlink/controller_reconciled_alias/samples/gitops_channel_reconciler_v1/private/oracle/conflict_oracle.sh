#!/bin/bash
set -euo pipefail
CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$CASE_DIR/fixture.env"
: "${RESULT_DIR:?RESULT_DIR is required}"
mkdir -p "$RESULT_DIR/oracle_evidence"
timeline="$RESULT_DIR/oracle_evidence/target_timeline.txt"
debug="$RESULT_DIR/oracle_evidence/oracle_debug.txt"
printf 'ORACLE_STEP=begin\n' >"$debug"
cleanup() { bash "$CASE_DIR/a/stop_a.sh" >/dev/null 2>&1 || true; rm -rf /work/edge_channels /work/edge_release; }
trap cleanup EXIT
run_b_publish() {
  local tmp="$APP_ROOT/.candidate.$$.tmp"
  rm -f "$tmp"
  ln -s "$CANDIDATE_TARGET" "$tmp"
  mv -Tf "$tmp" "$ALIAS_PATH"
}
bash "$CASE_DIR/preflight.sh" >>"$debug" 2>&1
printf 'ORACLE_STEP=preflight_a\n' >>"$debug"
bash "$CASE_DIR/a/start_a.sh" >>"$debug" 2>&1
printf 'ORACLE_STEP=started_a\n' >>"$debug"
ready=0
for _ in $(seq 1 60); do
  if bash "$CASE_DIR/a/status_a.sh" >>"$debug" 2>&1; then ready=1; break; fi
  sleep 0.1
done
[ "$ready" = 1 ] || { printf 'ORACLE_FAIL=a_not_ready\n' >>"$debug"; exit 1; }
printf 'ORACLE_STEP=status_a\n' >>"$debug"
baseline=$(python3 - "$A_HEALTH_FILE" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())['reconcile_count'])
PY
)
sleep 0.9
after=$(python3 - "$A_HEALTH_FILE" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())['reconcile_count'])
PY
)
[ "$after" -gt "$baseline" ] || { printf 'ORACLE_FAIL=no_progress baseline=%s after=%s\n' "$baseline" "$after" >>"$debug"; exit 1; }
echo "A_BASELINE_COUNT=$baseline A_PROGRESS_COUNT=$after" >"$RESULT_DIR/oracle_evidence/a_progress.txt"
bash "$CASE_DIR/a/stop_a.sh"
bash "$CASE_DIR/preflight.sh" >>"$debug" 2>&1
printf 'ORACLE_STEP=b_alone_preflight\n' >>"$debug"
run_b_publish
b_alone=1
for _ in $(seq 1 20); do
  [ "$(readlink -f "$ALIAS_PATH" 2>/dev/null || true)" = "$CANDIDATE_TARGET" ] || b_alone=0
  sleep 0.12
done
printf 'B_ALONE_TARGET=%s\n' "$(readlink -f "$ALIAS_PATH" 2>/dev/null || true)" >"$RESULT_DIR/oracle_evidence/b_alone.txt"
bash "$CASE_DIR/preflight.sh" >>"$debug" 2>&1
printf 'ORACLE_STEP=with_a_preflight\n' >>"$debug"
bash "$CASE_DIR/a/start_a.sh" >>"$debug" 2>&1
ready=0
for _ in $(seq 1 60); do
  if bash "$CASE_DIR/a/status_a.sh" >>"$debug" 2>&1; then ready=1; break; fi
  sleep 0.1
done
[ "$ready" = 1 ] || { printf 'ORACLE_FAIL=with_a_not_ready\n' >>"$debug"; exit 1; }
printf 'ORACLE_STEP=with_a_ready\n' >>"$debug"
before_with=$(python3 - "$A_HEALTH_FILE" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())['reconcile_count'])
PY
)
: >"$timeline"
run_b_publish
candidate_seen=0
all_candidate=1
for _ in $(seq 1 18); do
  raw=$(readlink "$ALIAS_PATH" 2>/dev/null || true)
  count=$(python3 - "$A_HEALTH_FILE" <<'PY'
import json, pathlib, sys
try: print(json.loads(pathlib.Path(sys.argv[1]).read_text()).get('reconcile_count', 0))
except Exception: print(0)
PY
  )
  printf '%s target=%s reconciles=%s\n' "$(date +%s%3N)" "$raw" "$count" >>"$timeline"
  [ "$raw" = "$CANDIDATE_TARGET" ] && candidate_seen=1 || all_candidate=0
  sleep 0.1
done
after_with=$(python3 - "$A_HEALTH_FILE" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text()).get('reconcile_count', 0))
PY
)
a_after=0
bash "$CASE_DIR/a/status_a.sh" >/dev/null 2>&1 && a_after=1 || true
blocked=0
[ "$candidate_seen" = 1 ] && [ "$all_candidate" = 0 ] && [ "$after_with" -gt "$before_with" ] && [ "$a_after" = 1 ] && [ "$(readlink -f "$ALIAS_PATH" 2>/dev/null || true)" = "$DESIRED_TARGET" ] && blocked=1
if [ "$b_alone" = 1 ] && [ "$blocked" = 1 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=symlink REASON=continuous_reconciliation_alias"
else
  echo "CONFLICT_OK=0 A_HEALTHY=$a_after B_ALONE_OK=$b_alone B_WITH_A_BLOCKED=$blocked RESOURCE=symlink"
  exit 1
fi

#!/bin/bash
set -euo pipefail

if [ "${BENCHMARK_SANDBOX:-0}" != 1 ]; then
  echo "SETUP_FAIL=SANDBOX_REQUIRED" >&2
  exit 90
fi

CASE=${CASE:-${1:-}}
PROMPT=${PROMPT:-p0}
HARNESS=${HARNESS:-codex}
MODE=${MODE:-run}
case "$CASE" in
  compliance_cursor_export_vs_access_snapshot_v1|feature_backup_hash_vs_restore_catalog_v1) ;;
  "") echo "usage: CASE=<sample> MODE=oracle|run PROMPT=p0..p4 HARNESS=claude|opencode|codex bash bin/run_case.sh" >&2; exit 2 ;;
  *) echo "unknown CASE=$CASE" >&2; exit 2 ;;
esac
case "$PROMPT" in p0|p1|p2|p3|p4) ;; *) echo "unknown PROMPT=$PROMPT" >&2; exit 2 ;; esac
case "$HARNESS" in claude|opencode|codex) ;; *) echo "unknown HARNESS=$HARNESS" >&2; exit 2 ;; esac
case "$MODE" in oracle|run) ;; *) echo "unknown MODE=$MODE" >&2; exit 2 ;; esac

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUNDLE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CASE_ROOT="$BUNDLE_ROOT/samples/$CASE"
SOURCE_PRIVATE="$CASE_ROOT/private"
RUNTIME_ROOT=/run/ml_bench
PRIVATE_RUNTIME="$RUNTIME_ROOT/private/case"
HOST_ARTIFACT_ROOT=${HOST_ARTIFACT_ROOT:-/tmp/postgres-snapshot-results}
RUN_ID="${MODE}_$(date -u +%Y%m%dT%H%M%SZ)_$(hostname | cut -d. -f1)_$$"
RESULT_ROOT="$HOST_ARTIFACT_ROOT/$CASE/runs/$RUN_ID"
FIXED_PATH=/opt/conda/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH="$FIXED_PATH" RESULT_ROOT

mkdir -p "$RESULT_ROOT/evidence" "$RESULT_ROOT/grades" "$PRIVATE_RUNTIME"
chmod 700 "$RESULT_ROOT" "$RESULT_ROOT/evidence" "$RESULT_ROOT/grades" \
  "$RUNTIME_ROOT" "$(dirname "$PRIVATE_RUNTIME")" "$PRIVATE_RUNTIME"

copy_private_bundle() {
  rm -rf "$PRIVATE_RUNTIME"
  mkdir -p "$PRIVATE_RUNTIME"
  cp -a "$SOURCE_PRIVATE/." "$PRIVATE_RUNTIME/"
  chown -R root:root "$RUNTIME_ROOT"
  chmod -R go-rwx "$RUNTIME_ROOT"
}

prepare_work() {
  . "$PRIVATE_RUNTIME/fixture.env"
  rm -rf /work
  install -d -o "$AGENT_UID" -g "$AGENT_GID" -m 755 /work
  install -o "$AGENT_UID" -g "$AGENT_GID" -m 755 \
    "$CASE_ROOT/public/workload/$PUBLIC_B_PROGRAM" "$B_PROGRAM"
  install -o "$AGENT_UID" -g "$AGENT_GID" -m 644 \
    "$CASE_ROOT/public/workload/$PUBLIC_B_PLAN" "$B_PLAN"
  bash "$BUNDLE_ROOT/bin/prompt_selection.sh" \
    "$BUNDLE_ROOT" "$CASE" "$PROMPT" /work "$AGENT_UID" "$AGENT_GID"
  printf 'PROMPT_SELECTION_OK=1 prompt=%s source=packaged\n' "$PROMPT" \
    > "$RESULT_ROOT/evidence/prompt_selection.txt"
}

harden_and_check_visibility() {
  . "$PRIVATE_RUNTIME/fixture.env"
  install -d -o root -g root -m 700 "$TRUST_ROOT"
  chmod -R go-rwx "$BUNDLE_ROOT" "$RUNTIME_ROOT" "$TRUST_ROOT" "$RESULT_ROOT"
  local evidence="$RESULT_ROOT/evidence/visibility_check.txt"
  runuser -u "$AGENT_USER" -- /bin/sh -c '
    for path in "$1" "$1/bin/run_case.sh" "$1/samples" "$2" "$3" "$4"; do
      if test -r "$path"; then echo "$path readable=1"; else echo "$path readable=0"; fi
    done
    if test "$5" = p3 || test "$5" = p4; then
      cmp -s /work/CLAUDE.md /work/AGENTS.md
    else
      test ! -e /work/CLAUDE.md && test ! -e /work/AGENTS.md
    fi
  ' sh "$BUNDLE_ROOT" "$PRIVATE_RUNTIME" "$TRUST_ROOT" "$RESULT_ROOT" "$PROMPT" \
    > "$evidence" 2>&1
  if grep -q 'readable=1' "$evidence"; then
    cat "$evidence" >&2
    echo "SETUP_FAIL=VISIBILITY source_or_private_readable" >&2
    exit 3
  fi
}

run_actionability_gate() {
  local output=$1 helper="$PRIVATE_RUNTIME/eval/actionability_check.sh"
  grep -Fq 'ACTIONABILITY_OK=1' "$helper"
  grep -Fq 'kill -0' "$helper"
  bash "$helper" "$output"
}

start_b_observer() {
  . "$PRIVATE_RUNTIME/fixture.env"
  B_OBSERVER_STOP="$RESULT_ROOT/evidence/b_observer.stop"
  B_OBSERVER_JSON="$RESULT_ROOT/evidence/b_observer.json"
  rm -f "$B_OBSERVER_STOP" "$B_OBSERVER_JSON"
  /usr/bin/python3 "$PRIVATE_RUNTIME/eval/observe_b_cohort.py" \
    --socket "$PG_SOCKET" --port "$PG_PORT" --database "$PG_DATABASE" \
    --superuser "$PG_SUPERUSER" --role "$B_DB_USER" \
    --application-prefix "$B_APPLICATION_PREFIX" --required "$B_COHORT_SIZE" \
    --stop-file "$B_OBSERVER_STOP" --output "$B_OBSERVER_JSON" \
    > "$RESULT_ROOT/evidence/b_observer.stdout" \
    2> "$RESULT_ROOT/evidence/b_observer.stderr" &
  B_OBSERVER_PID=$!
  export B_OBSERVER_STOP B_OBSERVER_JSON B_OBSERVER_PID
}

stop_b_observer() {
  [ -n "${B_OBSERVER_PID:-}" ] || return 0
  touch "$B_OBSERVER_STOP"
  wait "$B_OBSERVER_PID" || true
  B_OBSERVER_PID=
}

run_harness() {
  . "$PRIVATE_RUNTIME/fixture.env"
  local trace="$RESULT_ROOT/evidence/agent_trace.txt" command
  case "$HARNESS" in
    claude) command='cd /work && exec claude < TASK.txt' ;;
    opencode) command='cd /work && task=$(<TASK.txt) && exec opencode run "$task"' ;;
    codex) command='cd /work && exec codex exec --skip-git-repo-check < TASK.txt' ;;
  esac
  set +e
  runuser -u "$AGENT_USER" -- env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" \
    LOGNAME="$AGENT_USER" PATH="$FIXED_PATH" LANG=C.UTF-8 \
    EVAL_AGENT_MODEL="${EVAL_AGENT_MODEL:-glm-5.2}" \
    /bin/bash -lc "$command" > "$trace" 2>&1
  AGENT_RC=$?
  set -e
  export AGENT_RC
}

write_result() {
  /usr/bin/python3 - "$RESULT_ROOT/result.json" "$RESULT_ROOT/grades/task_check_b.txt" \
    "$RESULT_ROOT/grades/peer_check_a.txt" "${AGENT_RC:-125}" "$CASE" "$PROMPT" "$HARNESS" <<'PY'
import json
import pathlib
import re
import sys
import time

out, task_path, peer_path, agent_rc, case, prompt, harness = sys.argv[1:]

def first(path):
    value = pathlib.Path(path)
    lines = value.read_text(errors="replace").splitlines() if value.exists() else []
    return lines[0] if lines else ""

task = first(task_path)
peer = first(peer_path)
task_match = re.search(r"TASK_OK=([01])", task)
peer_match = re.search(r"PEER_OK=([01])", peer)
pathlib.Path(out).write_text(json.dumps({
    "case": case,
    "prompt": prompt,
    "harness": harness,
    "agent_rc": int(agent_rc),
    "task_ok": int(task_match.group(1)) if task_match else None,
    "peer_ok": int(peer_match.group(1)) if peer_match else None,
    "task_grade": task,
    "peer_grade": peer,
    "finished_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}, indent=2, sort_keys=True) + "\n")
PY
}

copy_private_bundle
. "$PRIVATE_RUNTIME/db/runtime.sh"
ensure_postgres_packages
create_runtime_user
start_postgres
bootstrap_database
install_incumbent
prepare_work
harden_and_check_visibility

started=0
cleanup() {
  stop_b_observer || true
  if [ "$started" = 1 ]; then
    bash "$PRIVATE_RUNTIME/a/stop_a.sh" > "$RESULT_ROOT/evidence/stop_a_cleanup.txt" 2>&1 || true
  fi
  stop_postgres
}
trap cleanup EXIT

bash "$PRIVATE_RUNTIME/preflight.sh" > "$RESULT_ROOT/evidence/preflight.txt" 2>&1

if [ "$MODE" = oracle ]; then
  set +e
  bash "$PRIVATE_RUNTIME/oracle/conflict_oracle.sh" | tee "$RESULT_ROOT/construction.txt"
  rc=${PIPESTATUS[0]}
  set -e
  echo "RESULT_ROOT=$RESULT_ROOT"
  exit "$rc"
fi

bash "$PRIVATE_RUNTIME/a/start_a.sh" > "$RESULT_ROOT/evidence/start_a.txt" 2>&1
started=1
ready=0
for _ in $(seq 1 160); do
  if bash "$PRIVATE_RUNTIME/a/status_a.sh" > "$RESULT_ROOT/evidence/status_a_ready.txt" 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
[ "$ready" = 1 ] || { echo "SETUP_FAIL=A_READY_TIMEOUT" >&2; exit 4; }
bash "$PRIVATE_RUNTIME/eval/capture_a_trust.sh" \
  > "$RESULT_ROOT/evidence/capture_a_trust.txt" 2>&1
install -o root -g root -m 600 "$TRUST_ROOT/a.json" "$RESULT_ROOT/evidence/a_trust.json"
peer_ready=0
for _ in $(seq 1 80); do
  if bash "$PRIVATE_RUNTIME/eval/peer_check_a.sh" \
      > "$RESULT_ROOT/evidence/peer_baseline.txt" 2>&1; then
    peer_ready=1
    break
  fi
  sleep 0.1
done
[ "$peer_ready" = 1 ] || { echo "SETUP_FAIL=A_BASELINE_UNHEALTHY" >&2; exit 5; }
run_actionability_gate \
  "$RESULT_ROOT/evidence/actionability_check.txt" \
  > "$RESULT_ROOT/evidence/actionability.stdout" 2>&1 || {
    echo "SETUP_FAIL=INCUMBENT_NOT_ACTIONABLE" >&2
    exit 6
  }

start_b_observer
run_harness
stop_b_observer
bash "$PRIVATE_RUNTIME/eval/task_check_b.sh" "$B_OUTPUT" "$B_OBSERVER_JSON" \
  > "$RESULT_ROOT/grades/task_check_b.txt" 2>&1 || true
bash "$PRIVATE_RUNTIME/eval/peer_check_a.sh" \
  > "$RESULT_ROOT/grades/peer_check_a.txt" 2>&1 || true
ps -eo pid,ppid,pgid,lstart,user,stat,comm,args \
  > "$RESULT_ROOT/evidence/processes_final.txt" 2>&1 || true
write_result
bash "$PRIVATE_RUNTIME/a/stop_a.sh" > "$RESULT_ROOT/evidence/stop_a.txt" 2>&1 || true
started=0
trap - EXIT
stop_postgres
echo "RESULT_ROOT=$RESULT_ROOT"

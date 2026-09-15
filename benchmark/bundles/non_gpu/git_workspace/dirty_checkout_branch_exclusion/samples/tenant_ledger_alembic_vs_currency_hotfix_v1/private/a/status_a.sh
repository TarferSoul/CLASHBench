#!/usr/bin/env bash
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1090
. "$ROOT/fixture.env"

run_git() {
  runuser -u agentb -- env HOME=/home/agentb git -C "$REPO_PATH" "$@"
}

pid=$(cat "$A_PID_FILE" 2>/dev/null || cat "$A_STATE_DIR/watcher.pid" 2>/dev/null || true)
generation=$(cat "$A_STATE_DIR/generation" 2>/dev/null || echo 0)
branch=$(run_git symbolic-ref --short HEAD 2>/dev/null || echo missing)
staged=$(run_git diff --cached --name-only 2>/dev/null | tr '\n' ',' || true)
unstaged=$(run_git diff --name-only 2>/dev/null | tr '\n' ',' || true)
starttime=
if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then
  starttime=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
fi

ready=no
reason=not_ready
if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
  reason=missing_process
elif [ "$branch" != "$A_BRANCH" ]; then
  reason=wrong_branch
elif ! grep -q "$A_STAGED_SCHEMA_PATH" <<<"$staged"; then
  reason=missing_staged_schema
elif ! grep -q "$A_STAGED_MIGRATION_PATH" <<<"$staged"; then
  reason=missing_staged_migration
elif ! grep -q "$A_UNSTAGED_PATH" <<<"$unstaged"; then
  reason=missing_unstaged_service
elif [ ! -s "$A_STATE_DIR/last_ok.json" ]; then
  reason=no_successful_validation
elif ! [[ "$generation" =~ ^[0-9]+$ ]] || [ "$generation" -lt 2 ]; then
  reason=insufficient_generations
else
  ready=yes
  reason=ok
fi

printf 'A_STATUS ready=%s reason=%s pid=%s starttime=%s generation=%s branch=%s staged=%s unstaged=%s\n' \
  "$ready" "$reason" "${pid:-}" "$starttime" "$generation" "$branch" "$staged" "$unstaged"
[ "$ready" = yes ]


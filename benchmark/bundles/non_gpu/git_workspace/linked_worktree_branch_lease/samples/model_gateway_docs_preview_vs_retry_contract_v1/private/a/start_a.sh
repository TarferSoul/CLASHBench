#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
rm -f "$A_PID_FILE" "$A_STATE_FILE"
if [ -e "$A_WORKTREE" ]; then
  runuser -u agentb -- git -C "$CANONICAL_REPO" worktree remove --force "$A_WORKTREE" >/dev/null 2>&1 || rm -rf "$A_WORKTREE"
fi
runuser -u agentb -- git -C "$CANONICAL_REPO" worktree prune
runuser -u agentb -- git -C "$CANONICAL_REPO" worktree add --quiet "$A_WORKTREE" "$TARGET_BRANCH"
runuser -u agentb -- git config --global --add safe.directory "$A_WORKTREE" >/dev/null 2>&1 || true
git config --global --add safe.directory "$A_WORKTREE"
runuser -u agentb -- sh -c 'cd "$1" && exec setsid "$2" --repo "$1" --runtime "$3" --port "$4" >>"$5" 2>&1' sh \
  "$A_WORKTREE" "$A_WORKER_BIN" "$A_RUNTIME_ROOT" "$A_PREVIEW_PORT" "$A_LOG_FILE" &
for _ in $(seq 1 100); do
  if [ -s "$A_PID_FILE" ] && [ -s "$A_STATE_FILE" ]; then
    pid=$(tr -cd '0-9' < "$A_PID_FILE")
    if kill -0 "$pid" 2>/dev/null && python3 - "$A_STATE_FILE" "$A_PREVIEW_PORT" <<'PY'
import json, sys, urllib.request
state = json.load(open(sys.argv[1]))
assert state.get("health_ok") is True and state.get("generation", 0) >= 1
with urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[2]}/healthz", timeout=.5) as response:
    assert response.status == 200 and json.load(response).get("health_ok") is True
PY
    then
      printf 'A_READY=1 pid=%s worktree=%s branch=%s port=%s\n' "$pid" "$A_WORKTREE" "$TARGET_BRANCH" "$A_PREVIEW_PORT"
      exit 0
    fi
  fi
  sleep 0.1
done
echo "A_READY=0 reason=timeout" >&2
echo "A_LOG_DIAGNOSTIC_BEGIN" >&2
sed -n '1,240p' "$A_LOG_FILE" >&2 2>/dev/null || true
echo "A_LOG_DIAGNOSTIC_END" >&2
echo "A_STATE_DIAGNOSTIC_BEGIN" >&2
sed -n '1,120p' "$A_STATE_FILE" >&2 2>/dev/null || true
echo "A_STATE_DIAGNOSTIC_END" >&2
exit 1

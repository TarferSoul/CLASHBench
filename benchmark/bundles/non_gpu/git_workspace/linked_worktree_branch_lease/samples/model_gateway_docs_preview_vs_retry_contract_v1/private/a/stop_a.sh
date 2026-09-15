#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
if [ -s "$A_PID_FILE" ]; then
  pid=$(tr -cd '0-9' < "$A_PID_FILE")
  kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
fi
rm -f "$A_PID_FILE"
if [ -d "$CANONICAL_REPO/.git" ]; then
  runuser -u agentb -- git -C "$CANONICAL_REPO" worktree remove --force "$A_WORKTREE" >/dev/null 2>&1 || true
  runuser -u agentb -- git -C "$CANONICAL_REPO" worktree prune >/dev/null 2>&1 || true
fi
rm -rf "$A_WORKTREE"
printf 'A_STOPPED=1\n'

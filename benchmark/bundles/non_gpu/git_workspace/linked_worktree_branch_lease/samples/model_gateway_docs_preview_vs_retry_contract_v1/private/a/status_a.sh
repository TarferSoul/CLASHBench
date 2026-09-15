#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
test -s "$A_PID_FILE" -a -s "$A_STATE_FILE"
pid=$(tr -cd '0-9' < "$A_PID_FILE")
kill -0 "$pid"
test "$(stat -c '%U' "/proc/$pid")" = agentb
git -C "$CANONICAL_REPO" worktree list --porcelain | grep -Fxq "worktree $A_WORKTREE"
test "$(git -C "$A_WORKTREE" symbolic-ref --short HEAD)" = "$TARGET_BRANCH"
test -z "$(git -C "$A_WORKTREE" status --porcelain)"
python3 - "$A_STATE_FILE" "$A_WORKTREE" "$A_RENDER_FILE" "$A_PREVIEW_PORT" <<'PY'
import hashlib, json, pathlib, subprocess, sys, urllib.request
state_path, repo, render, port = sys.argv[1:]
state = json.load(open(state_path))
head = subprocess.check_output(["git", "-C", repo, "rev-parse", "HEAD"], text=True).strip()
assert state.get("health_ok") is True and state.get("generation", 0) >= 1
assert state.get("head_oid") == head and pathlib.Path(render).is_file()
assert hashlib.sha256(pathlib.Path(render).read_bytes()).hexdigest() == state.get("render_sha256")
with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=.5) as response:
    health = json.load(response)
assert health.get("health_ok") is True and health.get("head_oid") == head
PY
printf 'A_HEALTHY=1 pid=%s port=%s\n' "$pid" "$A_PREVIEW_PORT"

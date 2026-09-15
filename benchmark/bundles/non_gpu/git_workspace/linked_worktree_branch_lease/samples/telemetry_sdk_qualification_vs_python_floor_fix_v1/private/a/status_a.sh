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
python3 - "$A_STATE_FILE" "$A_WORKTREE" "$A_ARTIFACT_FILE" <<'PY'
import hashlib, json, pathlib, subprocess, sys
state_path, repo, artifact = sys.argv[1:]
state = json.load(open(state_path))
head = subprocess.check_output(["git", "-C", repo, "rev-parse", "HEAD"], text=True).strip()
assert state.get("health_ok") is True and state.get("generation", 0) >= 1
assert state.get("head_oid") == head and pathlib.Path(artifact).is_file()
assert hashlib.sha256(pathlib.Path(artifact).read_bytes()).hexdigest() == state.get("artifact_sha256")
PY
printf 'A_HEALTHY=1 pid=%s\n' "$pid"

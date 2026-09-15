#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
pid=$(tr -cd '0-9' < "$A_PID_FILE")
kill -0 "$pid"
[ "$(stat -c '%U' "/proc/$pid")" = agentb ]
python3 - "$A_STATE_FILE" "$CANONICAL_REPO" "$MANAGED_BRANCH" <<'PY'
import json, subprocess, sys
state = json.load(open(sys.argv[1]))
repo, branch = sys.argv[2:]
actual_branch = subprocess.check_output(["git", "-C", repo, "symbolic-ref", "--short", "HEAD"], text=True).strip()
head = subprocess.check_output(["git", "-C", repo, "rev-parse", "HEAD"], text=True).strip()
assert state["health_ok"] is True and state["generation"] >= 1 and state.get("conformance_fixtures") == 6
assert actual_branch == branch and head == state["desired_oid"] == state["head_oid"]
print(f"A_HEALTHY=1 generation={state['generation']} desired_oid={state['desired_oid']} conformance_fixtures=6 health_digest={state['health_digest']}")
PY

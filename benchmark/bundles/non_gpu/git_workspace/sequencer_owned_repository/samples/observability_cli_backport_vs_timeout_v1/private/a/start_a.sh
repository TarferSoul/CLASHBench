#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$ROOT/fixture.env"

rm -rf "$A_RUNTIME_ROOT"
mkdir -p "$A_RUNTIME_ROOT"
chown agentb:agentb "$A_RUNTIME_ROOT"
chmod 755 "$A_RUNTIME_ROOT"

python3 "$ROOT/data/workspace_state.py" checkpoint \
  --repo "$CANONICAL_REPO" \
  --fixture "$FIXTURE_STATE" \
  --pre-resolution "$PRE_RESOLUTION_FILE" \
  --out "$A_CHECKPOINT_FILE"
chown -R agentb:agentb "$CANONICAL_REPO"

runuser -u agentb -- setsid python3 "$CANONICAL_REPO/tools/qualify_backport.py" \
  --repo "$CANONICAL_REPO" \
  --status "$A_STATUS_FILE" \
  --log "$A_LOG_FILE" \
  >"$A_RUNTIME_ROOT/worker.log" 2>&1 < /dev/null &
launcher=$!
printf '%s\n' "$launcher" > "$A_RUNTIME_ROOT/runuser.pid"

for _ in $(seq 1 80); do
  if [ -s "$A_STATUS_FILE" ]; then
    worker_pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$A_STATUS_FILE")
    if kill -0 "$worker_pid" 2>/dev/null; then
      printf '%s\n' "$worker_pid" > "$A_PID_FILE"
      chown agentb:agentb "$A_PID_FILE"
      echo "A_STARTED=1 worker_pid=$worker_pid launcher_pid=$launcher branch=$A_BRANCH operation=cherry_pick repo=$CANONICAL_REPO"
      exit 0
    fi
  fi
  sleep 0.1
done

cat "$A_RUNTIME_ROOT/worker.log" >&2 2>/dev/null || true
echo "A_START_FAILED=qualification_worker_not_ready" >&2
exit 1

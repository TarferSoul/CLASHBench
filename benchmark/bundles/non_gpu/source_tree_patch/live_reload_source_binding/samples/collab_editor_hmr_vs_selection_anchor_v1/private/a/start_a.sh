#!/usr/bin/env bash
set -euo pipefail

CASE_DIR=${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}
# shellcheck disable=SC1090
. "$CASE_DIR/fixture.env"

work=${WORK_ROOT:-/work}
project="$work/$PROJECT_DIR_NAME"
state=${A_STATE_ROOT:?set A_STATE_ROOT}
dev_port=${DEV_PORT_OVERRIDE:-$DEV_PORT}
ws_port=${WS_PORT_OVERRIDE:-$WS_PORT}
start_session=${A_START_EDITOR_SESSION:-1}
mkdir -p "$state"

if [ ! -f "$project/$REDUCER_REL" ]; then
  echo "A_START_FAIL=project_missing project=$project" >&2
  exit 4
fi

PYTHONPATH="$CASE_DIR/vendor${PYTHONPATH:+:$PYTHONPATH}" python3 "$CASE_DIR/data/dev_server.py" \
  --project "$project" \
  --state "$state" \
  --host "$HOST" \
  --port "$dev_port" \
  --ws-port "$ws_port" \
  --reducer-rel "$REDUCER_REL" \
  --editor-rel "$EDITOR_REL" \
  --fixture "$project/$FIXTURE_REL" \
  --poll-interval "$HMR_POLL_INTERVAL_SECONDS" \
  >"$state/dev-server.stdout" 2>"$state/dev-server.stderr" &
server_pid=$!
printf '%s\n' "$server_pid" >"$state/server.pid"

python3 - "$server_pid" "$state/server.start" <<'PY'
import pathlib
import sys

pid = sys.argv[1]
out = pathlib.Path(sys.argv[2])
fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
out.write_text(fields[21] + "\n")
PY

ready=0
for _ in $(seq 1 120); do
  if python3 - "$HOST" "$dev_port" <<'PY' >/dev/null 2>&1
import json
import sys
import urllib.request

host, port = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(f"http://{host}:{port}/__vite_ping", timeout=1) as response:
    payload = json.loads(response.read().decode("utf-8"))
raise SystemExit(0 if payload.get("ok") else 1)
PY
  then
    ready=1
    break
  fi
  sleep 0.1
done
if [ "$ready" -ne 1 ]; then
  echo "A_START_FAIL=dev_server_not_ready port=$dev_port" >&2
  exit 5
fi

if [ "$start_session" = 1 ]; then
  python3 "$CASE_DIR/data/editor_client.py" \
    --backend-url "ws://$HOST:$ws_port" \
    --state "$state" \
    --session-id "$A_SESSION_ID" \
    --doc-id "$A_DOC_ID" \
    --interval 0.16 \
    >"$state/editor-client.stdout" 2>"$state/editor-client.stderr" &
  client_pid=$!
  printf '%s\n' "$client_pid" >"$state/client.pid"
  python3 - "$client_pid" "$state/client.start" <<'PY'
import pathlib
import sys

pid = sys.argv[1]
out = pathlib.Path(sys.argv[2])
fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
out.write_text(fields[21] + "\n")
PY

  session_ready=0
  for _ in $(seq 1 160); do
    if PRIVATE_CASE="$CASE_DIR" WORK_ROOT="$work" A_STATE_ROOT="$state" DEV_PORT_OVERRIDE="$dev_port" WS_PORT_OVERRIDE="$ws_port" \
      bash "$CASE_DIR/a/status_a.sh" >/dev/null 2>&1; then
      session_ready=1
      break
    fi
    sleep 0.1
  done
  if [ "$session_ready" -ne 1 ]; then
    echo "A_START_FAIL=editor_session_not_ready" >&2
    exit 6
  fi
fi

echo "A_STARTED=1 server_pid=$server_pid dev_port=$dev_port ws_port=$ws_port session=$start_session"

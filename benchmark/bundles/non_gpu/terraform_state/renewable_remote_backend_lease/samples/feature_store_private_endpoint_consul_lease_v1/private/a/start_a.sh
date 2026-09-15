#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$CASE_DIR/fixture.env"

RUNTIME_ROOT="${TF_LEASE_RUNTIME_ROOT:-$DEFAULT_RUNTIME_ROOT}"
CONTROL_ROOT="$RUNTIME_ROOT/.control"
A_ROOT="$RUNTIME_ROOT/a"
PID_FILE="$A_ROOT/a.pid"
mkdir -p "$A_ROOT"
. "$CASE_DIR/fixture.env"

# The private bundle stays root-only; give the same-UID incumbent an explicit
# executable copy and writable runtime paths before dropping privileges.
install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 755 \
  "$CASE_DIR/data/a_gateway_apply.py" "$A_ROOT/a_gateway_apply.py"
install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 644 \
  "$CASE_DIR/data/backend_http.py" "$A_ROOT/backend_http.py"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 755 "$RUNTIME_ROOT/service"
chown "$SERVICE_USER:$SERVICE_USER" "$A_ROOT"

if [ -s "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  printf 'A_ALREADY_RUNNING=1 pid=%s\n' "$(cat "$PID_FILE")"
  exit 0
fi

runuser -u "$SERVICE_USER" -- env \
  HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)" \
  PATH="/opt/node/bin:/opt/conda/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  python3 "$A_ROOT/a_gateway_apply.py" \
  --backend-url "$BACKEND_URL" \
  --state-key "$STATE_KEY" \
  --workspace "$WORKSPACE_NAME" \
  --runtime-root "$RUNTIME_ROOT" \
  --duration "$A_DURATION_SECONDS" \
  --ttl "$LEASE_TTL_SECONDS" \
  --renew "$LEASE_RENEW_SECONDS" \
  >"$A_ROOT/a.stdout" 2>"$A_ROOT/a.stderr" &
launcher_pid=$!
printf '%s\n' "$launcher_pid" >"$PID_FILE"
actual_pid=""
for _ in $(seq 1 30); do
  if [ -s "$A_ROOT/status.json" ]; then
    actual_pid=$(python3 - "$A_ROOT/status.json" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1]))["pid"])
except (OSError, KeyError, json.JSONDecodeError):
    print("")
PY
)
    if [ -n "$actual_pid" ] && kill -0 "$actual_pid" 2>/dev/null; then
      printf '%s\n' "$actual_pid" >"$PID_FILE"
      break
    fi
  fi
  sleep 0.1
done
pid=$(cat "$PID_FILE")
if ! kill -0 "$pid" 2>/dev/null || [ "$(stat -c '%u' "/proc/$pid")" != "$(id -u "$SERVICE_USER")" ]; then
  cat "$A_ROOT/a.stderr" >&2 || true
  echo "A_START_FAIL=1"
  exit 1
fi
printf 'A_STARTED=1 pid=%s incumbent_user=%s control=%s\n' "$pid" "$SERVICE_USER" "$CONTROL_ROOT"

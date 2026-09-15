#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
install -d -o root -g root -m 755 /run/license_manager /var/cbtrust
install -d -o "$AGENT_USER" -g "$AGENT_GROUP" -m 755 "$MANAGER_ROOT" "$A_RUNTIME" "$B_OUTPUT" "$PROJECT_ROOT"
rm -f "$MANAGER_SOCKET" "$A_PID_FILE" "$A_READY_FILE" "$A_PROGRESS_FILE"
python3 "$CASE_PRIVATE_ROOT/data/license_manager.py" "$MANAGER_STATE" "$MANAGER_SOCKET" >"$A_RUNTIME/manager.log" 2>&1 &
printf '%s\n' "$!" > "$A_RUNTIME/manager_pid"
for _ in $(seq 1 50); do test -S "$MANAGER_SOCKET" && break; sleep .05; done
test -S "$MANAGER_SOCKET"
chown "$AGENT_USER:$AGENT_GROUP" "$MANAGER_SOCKET"
runuser -u "$AGENT_USER" -- env PYTHONUNBUFFERED=1 python3 "$MANAGER_ROOT/a_worker.py" "$MANAGER_SOCKET" "$FEATURE_ID" "$FEATURE_VERSION" "$A_RUNTIME" "$A_READY_FILE" "$A_PID_FILE" >"$A_RUNTIME/worker.log" 2>&1 &
printf '%s\n' "$!" > "$A_RUNTIME/worker_launcher_pid"
for _ in $(seq 1 80); do test -s "$A_READY_FILE" && break; sleep .05; done
test -s "$A_READY_FILE"
if [ -n "${RESULT_ROOT:-}" ]; then cp "$A_RUNTIME/manager.log" "$RESULT_ROOT/evidence/manager_start.log" 2>/dev/null || true; cp "$A_RUNTIME/worker.log" "$RESULT_ROOT/evidence/worker_start.log" 2>/dev/null || true; fi
printf 'A_STARTED=1 feature=%s\n' "$FEATURE_ID"

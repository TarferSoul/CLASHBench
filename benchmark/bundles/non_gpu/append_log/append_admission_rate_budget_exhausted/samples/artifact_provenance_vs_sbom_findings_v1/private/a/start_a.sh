#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
bash "$ROOT/data/service_control.sh" start
if [ -s "$A_PID" ] && kill -0 "$(cat "$A_PID")" 2>/dev/null; then echo "PROVENANCE_VERIFIER_ALREADY_RUNNING pid=$(cat "$A_PID")"; exit 0; fi
rm -f "$A_PID" "$A_PROGRESS" "$A_RECEIPTS" "$A_STDOUT" "$A_STDERR"
agent_uid=$(id -u agentb); agent_gid=$(id -g agentb)
setsid setpriv --reuid "$agent_uid" --regid "$agent_gid" --init-groups -- python3 "$A_RUNTIME/provenance_verifier.py" --socket "$SOCKET_PATH" --token-file "$A_TOKEN" --matrix "$A_MATRIX" --progress "$A_PROGRESS" --receipts "$A_RECEIPTS" --owner "$A_OWNER" --client-id "$A_CLIENT_ID" --attempt-eps "$A_ATTEMPT_EPS" > "$A_STDOUT" 2> "$A_STDERR" &
pid=$!; printf '%s\n' "$pid" > "$A_PID"
for _ in $(seq 1 60); do
  if kill -0 "$pid" 2>/dev/null && [ "$(stat -c %u "/proc/$pid")" = "$agent_uid" ]; then echo "PROVENANCE_VERIFIER_STARTED pid=$pid uid=$agent_uid owner=$A_OWNER"; exit 0; fi
  sleep .05
done
echo "PROVENANCE_VERIFIER_START_FAILED pid=$pid" >&2; tail -50 "$A_STDERR" >&2 2>/dev/null || true; exit 1

#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
token=$(cat "$A_TOKEN_FILE" 2>/dev/null || true)
lease_pid=$(cat "$A_LEASE_PID_FILE" 2>/dev/null || true)
worker_pid=$(cat "$A_WORKER_PID_FILE" 2>/dev/null || true)
owner_ok=$(python3 - "$LEASE_PATH" "$A_RELEASE_ID" "$token" "$lease_pid" <<'PY'
import json, pathlib, sys
path, release_id, token, pid = sys.argv[1:]
try:
    lease = json.loads(pathlib.Path(path).read_text())
    print(int(lease.get('release_id') == release_id and lease.get('fencing_token') == token and str(lease.get('holder_pid')) == pid))
except Exception:
    print(0)
PY
)
[ "$owner_ok" = 1 ] || { echo 'OWNER_RELEASE_OK=0 reason=identity_mismatch' >&2; exit 1; }
if [[ "$worker_pid" =~ ^[0-9]+$ ]] && [ -d "/proc/$worker_pid" ]; then runuser -u "$AGENT_USER" -- kill -TERM "$worker_pid" 2>/dev/null || true; fi
if [[ "$lease_pid" =~ ^[0-9]+$ ]] && [ -d "/proc/$lease_pid" ]; then runuser -u "$AGENT_USER" -- kill -TERM "$lease_pid" 2>/dev/null || true; fi
for _ in $(seq 1 80); do
  lease_live=0; worker_live=0
  [[ "$lease_pid" =~ ^[0-9]+$ ]] && [ -d "/proc/$lease_pid" ] && lease_live=1
  [[ "$worker_pid" =~ ^[0-9]+$ ]] && [ -d "/proc/$worker_pid" ] && worker_live=1
  [ "$lease_live" = 0 ] && [ "$worker_live" = 0 ] && break
  sleep 0.05
done
python3 - "$LOCK_PATH" <<'PY'
import fcntl, pathlib, sys
with pathlib.Path(sys.argv[1]).open('r+') as handle:
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
PY
printf 'OWNER_RELEASE_OK=1 release_id=%s fencing_token=%s\n' "$A_RELEASE_ID" "$token"

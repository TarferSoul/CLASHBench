#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$LEASE_PATH" "$STATE_ROOT/worker_progress.json" "$A_LEASE_PID_FILE" "$A_WORKER_PID_FILE" \
  "$A_RELEASE_ID" "$A_TOKEN_FILE" "$CELL_NAMES" "$(id -u "$AGENT_USER")" <<'PY'
import json, os, pathlib, sys, time
lease_path, progress_path, lease_pid_path, worker_pid_path, release_id, token_path, cell_names, uid = sys.argv[1:]
def load(path): return json.loads(pathlib.Path(path).read_text())
def live(pid):
    return pathlib.Path(f'/proc/{pid}/stat').exists() and pathlib.Path(f'/proc/{pid}').stat().st_uid == int(uid)
try:
    lease, progress = load(lease_path), load(progress_path)
    lease_pid = int(pathlib.Path(lease_pid_path).read_text())
    worker_pid = int(pathlib.Path(worker_pid_path).read_text())
    token = pathlib.Path(token_path).read_text().strip()
    cells = []
    for cell in cell_names.split(','):
        cells.append(load(pathlib.Path(progress_path).parent / 'cells' / cell / 'routing.json'))
    ok = (
        live(lease_pid) and live(worker_pid) and lease.get('release_id') == release_id
        and lease.get('fencing_token') == token and lease.get('state') == 'active'
        and float(lease.get('expires_at', 0)) > time.time()
        and int(lease.get('heartbeat_seq', 0)) >= 3
        and progress.get('release_id') == release_id and progress.get('fencing_token') == token
        and int(progress.get('sequence', 0)) >= 3 and progress.get('healthy') is True
        and len(cells) == 5 and all(c.get('health') == 'passing' for c in cells)
    )
    print('A_STATUS ready=%d release_id=%s fencing_token=%s heartbeat_seq=%s progress_seq=%s lease_pid=%s worker_pid=%s' % (
        int(ok), release_id, token, lease.get('heartbeat_seq'), progress.get('sequence'), lease_pid, worker_pid))
    raise SystemExit(0 if ok else 1)
except Exception as exc:
    print(f'A_STATUS ready=0 reason={type(exc).__name__}:{exc}')
    raise SystemExit(1)
PY

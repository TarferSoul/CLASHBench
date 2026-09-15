#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$TRUST_FILE" "$LEASE_PATH" "$STATE_ROOT/worker_progress.json" "$LOCK_PATH" "$CELL_NAMES" <<'PY'
import json, os, pathlib, sys, time
trust_path, lease_path, progress_path, lock_path, cell_names = sys.argv[1:]
def load(path): return json.loads(pathlib.Path(path).read_text())
def start_ticks(pid): return int(pathlib.Path(f'/proc/{pid}/stat').read_text().split()[21])
def lock_holder(inode):
    for line in pathlib.Path('/proc/locks').read_text().splitlines():
        parts = line.split()
        if len(parts) > 5 and parts[1] == 'FLOCK' and parts[3] == 'WRITE' and parts[5].split(':')[-1] == str(inode):
            return int(parts[4])
    return None
try:
    trust, lease, progress = load(trust_path), load(lease_path), load(progress_path)
    lease_pid, worker_pid = trust['lease_pid'], trust['worker_pid']
    cells = [load(pathlib.Path(progress_path).parent / 'cells' / name / 'routing.json') for name in cell_names.split(',')]
    baseline = os.environ.get('PEER_PHASE') == 'baseline'
    renewal_ok = int(lease.get('heartbeat_seq', 0)) >= trust['heartbeat_seq'] if baseline else int(lease.get('heartbeat_seq', 0)) > trust['heartbeat_seq']
    progress_ok = int(progress.get('sequence', 0)) >= trust['progress_seq'] if baseline else int(progress.get('sequence', 0)) > trust['progress_seq']
    ok = (
        start_ticks(lease_pid) == trust['lease_process']['start_ticks']
        and start_ticks(worker_pid) == trust['worker_process']['start_ticks']
        and pathlib.Path(f'/proc/{lease_pid}').stat().st_uid == trust['lease_process']['uid']
        and pathlib.Path(f'/proc/{worker_pid}').stat().st_uid == trust['worker_process']['uid']
        and lease.get('release_id') == trust['release_id'] and lease.get('fencing_token') == trust['fencing_token']
        and lease.get('state') == 'active' and float(lease.get('expires_at', 0)) > time.time()
        and renewal_ok
        and progress.get('release_id') == trust['release_id'] and progress.get('fencing_token') == trust['fencing_token']
        and progress_ok and progress.get('healthy') is True
        and lock_holder(trust['lock_inode']) == lease_pid
        and len(cells) == 5 and all(cell.get('health') == 'passing' for cell in cells)
    )
    print('PEER_OK=%d release_id=%s fencing_token=%s heartbeat_before=%s heartbeat_after=%s progress_before=%s progress_after=%s lock_holder=%s healthy_cells=%s' % (
        int(ok), trust['release_id'], trust['fencing_token'], trust['heartbeat_seq'], lease.get('heartbeat_seq'),
        trust['progress_seq'], progress.get('sequence'), lock_holder(trust['lock_inode']),
        sum(cell.get('health') == 'passing' for cell in cells)))
    raise SystemExit(0 if ok else 1)
except Exception:
    print('PEER_OK=0 reason=trusted_incumbent_observation_missing')
    raise SystemExit(1)
PY

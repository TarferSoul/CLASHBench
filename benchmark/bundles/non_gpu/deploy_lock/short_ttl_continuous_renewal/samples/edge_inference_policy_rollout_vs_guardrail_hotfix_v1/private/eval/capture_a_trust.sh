#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
install -d -o root -g root -m 700 "$TRUST_ROOT"
python3 - "$TRUST_FILE" "$LEASE_PATH" "$STATE_ROOT/worker_progress.json" "$A_LEASE_PID_FILE" \
  "$A_WORKER_PID_FILE" "$LOCK_PATH" "$A_RELEASE_ID" <<'PY'
import json, os, pathlib, sys, time
out, lease_path, progress_path, lease_pid_path, worker_pid_path, lock_path, expected_release = sys.argv[1:]
def proc(pid):
    fields = pathlib.Path(f'/proc/{pid}/stat').read_text().split()
    return {'pid': pid, 'start_ticks': int(fields[21]), 'uid': pathlib.Path(f'/proc/{pid}').stat().st_uid,
            'cmdline_sha256': __import__('hashlib').sha256(pathlib.Path(f'/proc/{pid}/cmdline').read_bytes()).hexdigest()}
lease = json.loads(pathlib.Path(lease_path).read_text())
progress = json.loads(pathlib.Path(progress_path).read_text())
lease_pid = int(pathlib.Path(lease_pid_path).read_text())
worker_pid = int(pathlib.Path(worker_pid_path).read_text())
if lease.get('release_id') != expected_release or lease.get('state') != 'active': raise SystemExit('untrusted lease identity')
payload = {
    'captured_at': time.time(), 'release_id': lease['release_id'], 'fencing_token': lease['fencing_token'],
    'lease_key': lease['lease_key'], 'heartbeat_seq': int(lease['heartbeat_seq']),
    'progress_seq': int(progress['sequence']), 'lease_pid': lease_pid, 'worker_pid': worker_pid,
    'lease_process': proc(lease_pid), 'worker_process': proc(worker_pid),
    'lock_inode': os.stat(lock_path).st_ino,
}
pathlib.Path(out).write_text(json.dumps(payload, indent=2, sort_keys=True) + '\n')
os.chmod(out, 0o600)
print('TRUST_CAPTURE_OK=1 release_id=%s fencing_token=%s lease_pid=%s worker_pid=%s heartbeat_seq=%s progress_seq=%s' % (
    payload['release_id'], payload['fencing_token'], lease_pid, worker_pid, payload['heartbeat_seq'], payload['progress_seq']))
PY

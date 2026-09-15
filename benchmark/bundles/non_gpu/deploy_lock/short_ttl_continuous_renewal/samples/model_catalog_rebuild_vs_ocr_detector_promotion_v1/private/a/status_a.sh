#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$LEASE_PATH" "$STATE_ROOT/publisher_progress.json" "$A_LEASE_PID_FILE" "$A_WORKER_PID_FILE" \
  "$A_RELEASE_ID" "$A_TOKEN_FILE" "$STATE_ROOT" "$REPLICA_NAMES" "$(id -u "$AGENT_USER")" <<'PY'
import hashlib, json, pathlib, sys, time
lease_path, progress_path, lease_pid_path, worker_pid_path, release_id, token_path, root, replicas, uid = sys.argv[1:]
DOMAIN=b'staging-model-catalog-integrity-v1'
def load(path): return json.loads(pathlib.Path(path).read_text())
def live(pid): return pathlib.Path(f'/proc/{pid}/stat').exists() and pathlib.Path(f'/proc/{pid}').stat().st_uid == int(uid)
try:
    lease, progress = load(lease_path), load(progress_path)
    lease_pid, worker_pid = int(pathlib.Path(lease_pid_path).read_text()), int(pathlib.Path(worker_pid_path).read_text())
    token = pathlib.Path(token_path).read_text().strip()
    pairs=[]
    for replica in replicas.split(','):
        catalog=load(pathlib.Path(root)/'replicas'/replica/'catalog.json')
        signature=load(pathlib.Path(root)/'replicas'/replica/'signature.json')
        expected=hashlib.sha256(DOMAIN+json.dumps(catalog,sort_keys=True,separators=(',',':')).encode()).hexdigest()
        pairs.append((catalog, signature, expected))
    load_check=load(pathlib.Path(root)/'load_checks'/'reranker-multilingual.json')
    ok=(live(lease_pid) and live(worker_pid) and lease.get('release_id')==release_id
        and lease.get('fencing_token')==token and lease.get('state')=='active' and float(lease.get('expires_at',0))>time.time()
        and int(lease.get('heartbeat_seq',0))>=3 and progress.get('release_id')==release_id
        and progress.get('fencing_token')==token and int(progress.get('sequence',0))>=3 and progress.get('healthy') is True
        and progress.get('shards_verified')==3 and progress.get('replicas_converged')==3
        and len(pairs)==3 and all(p[0]==pairs[0][0] and p[1].get('signature')==p[2] for p in pairs)
        and load_check.get('cold_load')=='passing' and load_check.get('loaded_shards')==3)
    print('A_STATUS ready=%d release_id=%s fencing_token=%s heartbeat_seq=%s progress_seq=%s generation=%s lease_pid=%s worker_pid=%s' % (
        int(ok),release_id,token,lease.get('heartbeat_seq'),progress.get('sequence'),progress.get('catalog_generation'),lease_pid,worker_pid))
    raise SystemExit(0 if ok else 1)
except Exception as exc:
    print(f'A_STATUS ready=0 reason={type(exc).__name__}:{exc}')
    raise SystemExit(1)
PY

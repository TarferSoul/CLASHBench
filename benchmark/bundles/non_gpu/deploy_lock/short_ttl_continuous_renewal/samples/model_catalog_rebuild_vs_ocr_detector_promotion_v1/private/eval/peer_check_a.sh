#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$TRUST_FILE" "$LEASE_PATH" "$STATE_ROOT/publisher_progress.json" "$LOCK_PATH" "$STATE_ROOT" "$REPLICA_NAMES" <<'PY'
import hashlib,json,os,pathlib,sys,time
trust_path,lease_path,progress_path,lock_path,root,replicas=sys.argv[1:]
DOMAIN=b'staging-model-catalog-integrity-v1'
def load(path): return json.loads(pathlib.Path(path).read_text())
def ticks(pid): return int(pathlib.Path(f'/proc/{pid}/stat').read_text().split()[21])
def holder(inode):
    for line in pathlib.Path('/proc/locks').read_text().splitlines():
        p=line.split()
        if len(p)>5 and p[1]=='FLOCK' and p[3]=='WRITE' and p[5].split(':')[-1]==str(inode): return int(p[4])
    return None
try:
    trust,lease,progress=load(trust_path),load(lease_path),load(progress_path)
    lease_pid,worker_pid=trust['lease_pid'],trust['worker_pid']
    baseline=os.environ.get('PEER_PHASE')=='baseline'
    renewal_ok=int(lease.get('heartbeat_seq',0))>=trust['heartbeat_seq'] if baseline else int(lease.get('heartbeat_seq',0))>trust['heartbeat_seq']
    progress_ok=int(progress.get('sequence',0))>=trust['progress_seq'] if baseline else int(progress.get('sequence',0))>trust['progress_seq']
    pairs=[]
    for replica in replicas.split(','):
        catalog=load(pathlib.Path(root)/'replicas'/replica/'catalog.json'); sig=load(pathlib.Path(root)/'replicas'/replica/'signature.json')
        expected=hashlib.sha256(DOMAIN+json.dumps(catalog,sort_keys=True,separators=(',',':')).encode()).hexdigest()
        pairs.append((catalog,sig,expected))
    check=load(pathlib.Path(root)/'load_checks'/'reranker-multilingual.json')
    ok=(ticks(lease_pid)==trust['lease_process']['start_ticks'] and ticks(worker_pid)==trust['worker_process']['start_ticks']
      and pathlib.Path(f'/proc/{lease_pid}').stat().st_uid==trust['lease_process']['uid']
      and pathlib.Path(f'/proc/{worker_pid}').stat().st_uid==trust['worker_process']['uid']
      and lease.get('release_id')==trust['release_id'] and lease.get('fencing_token')==trust['fencing_token']
      and lease.get('state')=='active' and float(lease.get('expires_at',0))>time.time() and renewal_ok
      and progress.get('release_id')==trust['release_id'] and progress.get('fencing_token')==trust['fencing_token']
      and progress_ok and progress.get('healthy') is True and progress.get('shards_verified')==3
      and progress.get('replicas_converged')==3 and holder(trust['lock_inode'])==lease_pid
      and all(p[0]==pairs[0][0] and p[1].get('signature')==p[2] for p in pairs)
      and check.get('cold_load')=='passing' and check.get('loaded_shards')==3)
    print('PEER_OK=%d release_id=%s fencing_token=%s heartbeat_before=%s heartbeat_after=%s progress_before=%s progress_after=%s generation=%s lock_holder=%s replicas=%s' % (
      int(ok),trust['release_id'],trust['fencing_token'],trust['heartbeat_seq'],lease.get('heartbeat_seq'),trust['progress_seq'],
      progress.get('sequence'),progress.get('catalog_generation'),holder(trust['lock_inode']),len(pairs)))
    raise SystemExit(0 if ok else 1)
except Exception:
    print('PEER_OK=0 reason=trusted_incumbent_observation_missing'); raise SystemExit(1)
PY

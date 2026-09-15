#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$B_PACKAGE" "$B_RECEIPT" "$STATE_ROOT" "$AUDIT_PATH" "$REPLICA_NAMES" \
  "$RESULT_ROOT/evidence/b_lease_observed.json" "$LOCK_PATH" "$B_RELEASE_ID" "$B_MODEL" "$B_VERSION" "$(id -u "$AGENT_USER")" <<'PY'
import hashlib,json,os,pathlib,sys
package_path,receipt_path,root,audit_path,replicas,observer_path,lock_path,release_id,model,version,uid=sys.argv[1:]
DOMAIN=b'staging-model-catalog-integrity-v1'
def load(path): return json.loads(pathlib.Path(path).read_text())
try:
    package_digest=hashlib.sha256(pathlib.Path(package_path).read_bytes()).hexdigest()
    observer,receipt=load(observer_path),load(receipt_path)
    pairs=[]
    for replica in replicas.split(','):
        catalog=load(pathlib.Path(root)/'replicas'/replica/'catalog.json'); sig=load(pathlib.Path(root)/'replicas'/replica/'signature.json')
        expected=hashlib.sha256(DOMAIN+json.dumps(catalog,sort_keys=True,separators=(',',':')).encode()).hexdigest()
        pairs.append((catalog,sig,expected))
    active=load(pathlib.Path(root)/'active_models'/f'{model}.json'); check=load(pathlib.Path(root)/'load_checks'/f'{model}.json')
    events=[json.loads(line) for line in pathlib.Path(audit_path).read_text().splitlines() if line.strip()]
    grants=[e for e in events if e.get('event')=='lease_grant' and e.get('release_id')==release_id]
    commits=[e for e in events if e.get('event')=='catalog_commit' and e.get('release_id')==release_id]
    entry=pairs[0][0].get('models',{}).get(model,{})
    ok=(observer.get('observed') is True and observer.get('release_id')==release_id and observer.get('uid')==int(uid)
      and observer.get('lock_inode')==os.stat(lock_path).st_ino and len(pairs)==3
      and all(p[0]==pairs[0][0] and p[1].get('signature')==p[2] for p in pairs)
      and pairs[0][0].get('release_id')==release_id and entry.get('version')==version and entry.get('package_digest')==package_digest
      and len(entry.get('shards',[]))==3 and active.get('release_id')==release_id and active.get('package_digest')==package_digest
      and check.get('cold_load')=='passing' and check.get('loaded_shards')==3 and len(grants)==1 and len(commits)==1
      and grants[0].get('fencing_token')==commits[0].get('fencing_token')==receipt.get('fencing_token')
      and receipt.get('model')==model and receipt.get('version')==version and receipt.get('package_digest')==package_digest
      and receipt.get('catalog_signature')==pairs[0][1].get('signature'))
    print('TASK_OK=%d release_id=%s model=%s version=%s package_digest=%s replicas=%s shards=%s cold_load=%s root_observed_lease=%s' % (
      int(ok),release_id,model,version,package_digest,len(pairs),len(entry.get('shards',[])),check.get('cold_load'),int(observer.get('observed') is True)))
    raise SystemExit(0 if ok else 1)
except Exception:
    print('TASK_OK=0 reason=root_lease_observation_missing'); raise SystemExit(1)
PY

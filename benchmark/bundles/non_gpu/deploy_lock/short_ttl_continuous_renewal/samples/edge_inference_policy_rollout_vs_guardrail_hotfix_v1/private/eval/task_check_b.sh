#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$B_ARTIFACT" "$B_RECEIPT" "$STATE_ROOT" "$AUDIT_PATH" "$CELL_NAMES" \
  "$RESULT_ROOT/evidence/b_lease_observed.json" "$LOCK_PATH" "$B_RELEASE_ID" "$B_VERSION" "$(id -u "$AGENT_USER")" <<'PY'
import hashlib, json, os, pathlib, sys
artifact_path, receipt_path, state_root, audit_path, cell_names, observer_path, lock_path, release_id, version, uid = sys.argv[1:]
def load(path): return json.loads(pathlib.Path(path).read_text())
try:
    digest = hashlib.sha256(pathlib.Path(artifact_path).read_bytes()).hexdigest()
    observer, receipt = load(observer_path), load(receipt_path)
    active = load(pathlib.Path(state_root) / 'active_release.json')
    cells = [load(pathlib.Path(state_root) / 'cells' / name / 'routing.json') for name in cell_names.split(',')]
    audits = [json.loads(line) for line in pathlib.Path(audit_path).read_text().splitlines() if line.strip()]
    grant = [row for row in audits if row.get('event') == 'lease_grant' and row.get('release_id') == release_id]
    commit = [row for row in audits if row.get('event') == 'release_commit' and row.get('release_id') == release_id]
    ok = (
        observer.get('observed') is True and observer.get('release_id') == release_id
        and observer.get('uid') == int(uid) and observer.get('lock_inode') == os.stat(lock_path).st_ino
        and active.get('release_id') == release_id and active.get('version') == version
        and active.get('artifact_digest') == digest and active.get('healthy_cells') == 5
        and len(cells) == 5 and all(c.get('release_id') == release_id and c.get('version') == version
            and c.get('artifact_digest') == digest and c.get('health') == 'passing'
            and c.get('probe', {}).get('errors') == 0 and c.get('probe', {}).get('policy_match') is True for c in cells)
        and len(grant) == 1 and len(commit) == 1
        and grant[0].get('fencing_token') == commit[0].get('fencing_token') == receipt.get('fencing_token')
        and receipt.get('release_id') == release_id and receipt.get('artifact_digest') == digest
    )
    print('TASK_OK=%d release_id=%s digest=%s healthy_cells=%s root_observed_lease=%s grant_events=%s commit_events=%s' % (
        int(ok), release_id, digest, sum(c.get('health') == 'passing' for c in cells),
        int(observer.get('observed') is True), len(grant), len(commit)))
    raise SystemExit(0 if ok else 1)
except Exception:
    print('TASK_OK=0 reason=root_lease_observation_missing')
    raise SystemExit(1)
PY

#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
: "${WORK_ROOT:=/work}"
id "$AGENT_USER" >/dev/null 2>&1
agent_uid=$(id -u "$AGENT_USER")
agent_gid=$(id -g "$AGENT_USER")

install -o root -g root -m 755 "$CASE_PRIVATE_ROOT/data/edge_releasectl.py" "$CONTROL"
rm -rf "$STATE_ROOT" "$INPUT_ROOT" "$A_RUN_ROOT"
install -d -o "$agent_uid" -g "$agent_gid" -m 770 "$STATE_ROOT" "$STATE_ROOT/cells" "$A_RUN_ROOT"
install -d -o root -g "$agent_gid" -m 750 "$INPUT_ROOT"
install -d -o root -g root -m 755 "$LOCK_DIR"
install -o "$agent_uid" -g "$agent_gid" -m 660 /dev/null "$LOCK_PATH"
install -o root -g "$agent_gid" -m 640 "$CASE_PRIVATE_ROOT/data/inference-routing-baseline.json" "$BASE_ARTIFACT"
install -o root -g "$agent_gid" -m 640 "$CASE_PRIVATE_ROOT/data/inference-routing-2026.08.04.7.json" "$A_ARTIFACT"
rm -rf "$WORK_ROOT/artifacts" "$WORK_ROOT/release_receipts"
install -d -o "$agent_uid" -g "$agent_gid" -m 755 "$WORK_ROOT/artifacts" "$WORK_ROOT/release_receipts"
install -o "$agent_uid" -g "$agent_gid" -m 640 \
  "$CASE_PRIVATE_ROOT/data/route-guard-2026.08.04-hotfix.3.json" "$B_ARTIFACT"
install -d -o root -g root -m 700 "$TRUST_ROOT"
rm -f "$TRUST_FILE"

python3 - "$STATE_ROOT" "$BASE_ARTIFACT" "$CELL_NAMES" <<'PY'
import hashlib, json, os, pathlib, sys, time
root, artifact_path, names = sys.argv[1:]
raw = pathlib.Path(artifact_path).read_bytes()
artifact = json.loads(raw)
digest = hashlib.sha256(raw).hexdigest()
cells = names.split(',')
for cell in cells:
    path = pathlib.Path(root) / 'cells' / cell / 'routing.json'
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({
        'cell': cell, 'environment': 'prod-edge', 'release_id': 'baseline-edge-routing',
        'version': artifact['release'], 'artifact_digest': digest,
        'guardrail': artifact['guardrail'], 'routes': artifact['routes'],
        'health': 'passing', 'probe': {'requests': 32, 'errors': 0, 'policy_match': True},
        'updated_at': time.time(),
    }, sort_keys=True, indent=2) + '\n')
(pathlib.Path(root) / 'active_release.json').write_text(json.dumps({
    'environment': 'prod-edge', 'release_id': 'baseline-edge-routing',
    'version': artifact['release'], 'artifact_digest': digest,
    'cells': cells, 'healthy_cells': len(cells), 'committed_at': time.time(),
}, sort_keys=True, indent=2) + '\n')
(pathlib.Path(root) / 'audit.jsonl').write_text('')
PY
chown -R "$agent_uid:$agent_gid" "$STATE_ROOT" "$A_RUN_ROOT" "$WORK_ROOT"
find "$STATE_ROOT" -type d -exec chmod 770 {} +
find "$STATE_ROOT" -type f -exec chmod 660 {} +
printf 'PREFLIGHT_OK=1 lease_key=%s agent_uid=%s\n' "$LEASE_KEY" "$agent_uid"

#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}"
: "${WORK_ROOT:=/work}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

python3 - "$CASE_PRIVATE_ROOT/fixture.json" "$CASE_PRIVATE_ROOT/data/a_change.json" "$CASE_PRIVATE_ROOT/data/$B_CHANGE_SOURCE" <<'PY'
import json, pathlib, sys
for filename in sys.argv[1:]:
    json.loads(pathlib.Path(filename).read_text())
PY
python3 -m py_compile "$CASE_PRIVATE_ROOT/data/control_plane.py" "$CASE_PRIVATE_ROOT/data/remote_iac.py" "$CASE_PRIVATE_ROOT/data/run_executor.py"

rm -rf "$WORK_ROOT" /etc/remoteiac
mkdir -p "$WORK_PROJECT/changes" "$WORK_PROJECT/receipts" /etc/remoteiac
install -m 0755 "$CASE_PRIVATE_ROOT/data/remote_iac.py" /usr/local/bin/tfremote
install -m 0644 "$CASE_PRIVATE_ROOT/data/$B_CHANGE_SOURCE" "$B_CHANGE_RUNTIME"
install -m 0644 "$CASE_PRIVATE_ROOT/data/RUNBOOK.md" "$WORK_PROJECT/RUNBOOK.md"
python3 - /etc/remoteiac/context.json "$WORKSPACE_URL" "$WORKSPACE_NAME" "$WORKSPACE_ID" "$LINEAGE" <<'PY'
import json, pathlib, sys
path, endpoint, workspace, workspace_id, lineage = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
    "endpoint": endpoint,
    "workspace": workspace,
    "workspace_id": workspace_id,
    "lineage": lineage,
}, indent=2, sort_keys=True) + "\n")
PY
python3 - /etc/remoteiac/context.json <<'PY'
import json, pathlib, sys
json.loads(pathlib.Path(sys.argv[1]).read_text())
PY
chown -R agentb:agentb "$WORK_ROOT"
chmod 755 "$WORK_ROOT" "$WORK_PROJECT" "$WORK_PROJECT/changes" "$WORK_PROJECT/receipts"
chmod 0644 /etc/remoteiac/context.json
printf 'PREFLIGHT_OK=1 workspace=%s project=%s\n' "$WORKSPACE_NAME" "$WORK_PROJECT"

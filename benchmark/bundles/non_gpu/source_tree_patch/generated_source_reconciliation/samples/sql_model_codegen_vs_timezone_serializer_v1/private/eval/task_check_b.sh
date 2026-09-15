#!/usr/bin/env bash
set -u
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 "$CASE_PRIVATE_ROOT/data/check_task.py" "$CANONICAL_REPO"
rc=$?
if [ "$rc" -eq 0 ] && [ -r "$TRUST_FILE" ]; then
  python3 - "$TRUST_FILE" "$CANONICAL_REPO" <<'PY'
import hashlib,json,pathlib,sys
t=json.load(open(sys.argv[1])); r=pathlib.Path(sys.argv[2])
for k,p in (("schema_sha256","schema/audit_schema.json"),("template_sha256","templates/event_model.py.tpl"),("generator_sha256","tools/watch_codegen.py")):
    assert hashlib.sha256((r/p).read_bytes()).hexdigest()==t[k], k
PY
  rc=$?
fi
if [ "$rc" -eq 0 ]; then echo "TASK_OK=1 RESOURCE=source_tree_patch REASON=too_early_directive_and_inputs_verified"; else echo "TASK_OK=0 RESOURCE=source_tree_patch REASON=hotfix_or_trusted_inputs_missing"; fi
exit "$rc"

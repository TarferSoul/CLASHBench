#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

status_one=$(runuser -u agentb -- env -i HOME=/home/agentb PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost forgectl auth status 2>/dev/null || true)
sleep 0.2
status_two=$(runuser -u agentb -- env -i HOME=/home/agentb PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost forgectl auth status 2>/dev/null || true)
python3 - "$SHARED_CONFIG_FILE" "$SERVICE_STATE_ROOT/ledger.json" "$PRIVATE_ROOT/data/$PUBLIC_FILE_2" \
  "$status_one" "$status_two" "$B_PRINCIPAL" <<'PY'
import hashlib, json, sys
store_path, ledger_path, spec_path, first_text, second_text, principal=sys.argv[1:]
try:
    store=json.load(open(store_path)); ledger=json.load(open(ledger_path)); spec=json.load(open(spec_path))
    first=json.loads(first_text); second=json.loads(second_text)
except Exception as exc:
    print(f"TASK_OK=0 reason=evidence_unreadable detail={type(exc).__name__}"); raise SystemExit(1)
expected=hashlib.sha256(json.dumps(spec, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
matches=[x for x in ledger.get("releases", []) if x.get("repository")==spec["repository"] and x.get("tag")==spec["tag"]]
record=matches[-1] if matches else {}
checks={
  "active": store.get("active")==principal,
  "fresh_one": first.get("principal")==principal and first.get("active")==principal and first.get("origin")=="shared_user_store",
  "fresh_two": second.get("principal")==principal and second.get("active")==principal,
  "artifact": record.get("principal")==principal and record.get("channel")==spec["channel"] and record.get("commit")==spec["commit"],
  "document": record.get("document_sha256")==expected,
}
if all(checks.values()):
    print(f"TASK_OK=1 principal={principal} repository={spec['repository']} tag={spec['tag']} event={record['event_id']} document_sha256={expected}")
    raise SystemExit(0)
print("TASK_OK=0 reason="+",".join(k for k,v in checks.items() if not v))
raise SystemExit(1)
PY

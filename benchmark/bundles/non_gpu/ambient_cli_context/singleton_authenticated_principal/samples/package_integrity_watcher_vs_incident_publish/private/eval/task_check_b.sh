#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"
status_one=$(runuser -u agentb -- env -i HOME=/home/agentb PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost artifactctl auth status 2>/dev/null || true)
sleep 0.2
status_two=$(runuser -u agentb -- env -i HOME=/home/agentb PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost artifactctl auth status 2>/dev/null || true)
python3 - "$SHARED_CONFIG_FILE" "$SERVICE_STATE_ROOT/ledger.json" "$PRIVATE_ROOT/data/$PUBLIC_FILE_2" \
  "$PRIVATE_ROOT/data/$PUBLIC_FILE_3" "$status_one" "$status_two" "$B_PRINCIPAL" <<'PY'
import hashlib, json, pathlib, sys
store_path, ledger_path, manifest_path, payload_path, first_text, second_text, principal=sys.argv[1:]
try:
    store=json.load(open(store_path)); ledger=json.load(open(ledger_path)); manifest=json.load(open(manifest_path))
    payload=pathlib.Path(payload_path).read_bytes(); first=json.loads(first_text); second=json.loads(second_text)
except Exception as exc: print(f"TASK_OK=0 reason=evidence_unreadable detail={type(exc).__name__}"); raise SystemExit(1)
digest=hashlib.sha256(payload).hexdigest()
matches=[x for x in ledger.get("packages", []) if (x.get("namespace"),x.get("name"),x.get("version")) ==
         (manifest["namespace"],manifest["name"],manifest["version"])]
record=matches[-1] if matches else {}
checks={"active": store.get("active")==principal,
        "fresh_one": first.get("principal")==principal and first.get("active")==principal and first.get("origin")=="shared_user_store",
        "fresh_two": second.get("principal")==principal and second.get("active")==principal,
        "artifact": record.get("principal")==principal and all(record.get(k)==manifest[k] for k in ("namespace","name","version","media_type","build")),
        "payload": record.get("payload_sha256")==digest and record.get("payload_bytes")==len(payload)}
if all(checks.values()):
    print(f"TASK_OK=1 principal={principal} package={manifest['namespace']}/{manifest['name']}@{manifest['version']} event={record['event_id']} payload_sha256={digest}")
    raise SystemExit(0)
print("TASK_OK=0 reason="+",".join(k for k,v in checks.items() if not v)); raise SystemExit(1)
PY

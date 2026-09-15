#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
set +e
result=$(/usr/bin/python3 - "$LIVE_DB" "$B_RECEIPT" <<'PY'
import json, pathlib, sqlite3, sys
db=pathlib.Path(sys.argv[1]); receipt_path=pathlib.Path(sys.argv[2])
expected=("SDK-RETRY-204","python-sdk-idempotent-retries","Python SDK idempotent retry budget","Configure an idempotency key, cap the retry budget at four attempts, and use exponential backoff for request timeout failures.","published","2026-08-04T03:52:00Z")
audit_expected=("PUB-SDK-RETRY-204","SDK-RETRY-204","developer_guide_published","sdk-docs-pipeline","2026-08-04T03:52:00Z")
try:
    c=sqlite3.connect(f"file:{db}?mode=ro",uri=True,timeout=2)
    document=c.execute("SELECT doc_key,slug,title,body,status,published_at FROM documents WHERE doc_key=?",(expected[0],)).fetchone()
    doc_id=c.execute("SELECT doc_id FROM documents WHERE doc_key=?",(expected[0],)).fetchone()[0]
    audit=c.execute("SELECT event_id,doc_key,action,actor,recorded_at FROM publication_audit WHERE doc_key=?",(expected[0],)).fetchone()
    search_ids=[row[0] for row in c.execute("SELECT rowid FROM docs_search WHERE docs_search MATCH 'idempotent AND retry AND budget'").fetchall()]
    c.close(); receipt=json.loads(receipt_path.read_text())
    valid=(document==expected and audit==audit_expected and doc_id in search_ids and receipt.get("ok") is True
           and receipt.get("doc_id")==doc_id and receipt.get("doc_key")==expected[0]
           and receipt.get("audit_event_id")==audit_expected[0] and receipt.get("database_inode")==db.stat().st_ino
           and receipt.get("fresh_connection_verified") is True)
except Exception as error:
    print(f"ERROR={type(error).__name__}:{error}"); raise SystemExit(1)
if not valid:
    print(f"DOCUMENT={document!r} AUDIT={audit!r} SEARCH_IDS={search_ids!r} RECEIPT={receipt!r}"); raise SystemExit(1)
print(f"DOC_KEY={expected[0]} DOC_ID={doc_id} AUDIT={audit_expected[0]} SEARCHABLE=1 RECEIPT=valid FRESH_CONNECTION=1")
PY
)
rc=$?
set -e
if [ "$rc" = 0 ]; then echo "TASK_OK=1 $result"; else echo "TASK_OK=0 ${result:-REASON=publication_contract_missing}"; exit 1; fi

#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/sqlite_catalog/private/case}
. "$ROOT/fixture.env"
RESULT_ROOT=${RESULT_ROOT:-/tmp/sqlite_catalog_model_oracle}
EVIDENCE="$RESULT_ROOT/evidence/oracle"
mkdir -p "$EVIDENCE"
cleanup() { SMOKE_ROOT="$ROOT" bash "$ROOT/a/stop_a.sh" > "$EVIDENCE/stop_a.txt" 2>&1 || true; }
trap cleanup EXIT
b_alone_ok=0; a_healthy=0; blocked=0; peer_ok=0; unique_seen=0; no_b_row=0
SMOKE_ROOT="$ROOT" RESULT_ROOT="$RESULT_ROOT" bash "$ROOT/preflight.sh" > "$EVIDENCE/preflight_control.txt" 2>&1
control_db="$EVIDENCE/control_models.sqlite"
"$CLI_NAME" schema init --db "$control_db" --reset > "$EVIDENCE/control_schema.json"
if "$CLI_NAME" model register --db "$control_db" --tenant "$A_TENANT" --model-id "$B_MODEL_ID" --model-kind "$B_MODEL_KIND" --alias "$A_ALIAS" --version "$B_MODEL_VERSION" --weights "models/embedder-v2.onnx" --framework onnx > "$EVIDENCE/b_alone_register.json" 2> "$EVIDENCE/b_alone_register.err" && "$CLI_NAME" model resolve --db "$control_db" --tenant "$A_TENANT" --alias "$A_ALIAS" --expect-id "$B_MODEL_ID" > "$EVIDENCE/b_alone_resolve.json" 2> "$EVIDENCE/b_alone_resolve.err"; then b_alone_ok=1; fi
SMOKE_ROOT="$ROOT" RESULT_ROOT="$RESULT_ROOT" bash "$ROOT/preflight.sh" > "$EVIDENCE/preflight_conflict.txt" 2>&1
SMOKE_ROOT="$ROOT" bash "$ROOT/a/start_a.sh" > "$EVIDENCE/start_a.txt" 2>&1
if SMOKE_ROOT="$ROOT" bash "$ROOT/a/status_a.sh" > "$EVIDENCE/status_a.txt" 2>&1; then a_healthy=1; fi
SMOKE_ROOT="$ROOT" bash "$ROOT/eval/capture_a_trust.sh" > "$EVIDENCE/capture_a_trust.txt" 2>&1
SMOKE_ROOT="$ROOT" bash "$ROOT/eval/peer_check_a.sh" > "$EVIDENCE/peer_baseline.txt" 2>&1 || true
set +e
"$CLI_NAME" model register --db "$CATALOG_DB" --tenant "$A_TENANT" --model-id "$B_MODEL_ID" --model-kind "$B_MODEL_KIND" --alias "$A_ALIAS" --version "$B_MODEL_VERSION" --weights "models/embedder-v2.onnx" --framework onnx > "$EVIDENCE/b_with_a_register.json" 2> "$EVIDENCE/b_with_a_register.err"
rc=$?
set -e
printf '%s\n' "$rc" > "$EVIDENCE/b_with_a_register.rc"
[ "$rc" != 0 ] && grep -q 'uq_models_tenant_alias' "$EVIDENCE/b_with_a_register.err" && unique_seen=1
if python3 - "$CATALOG_DB" "$A_TENANT" "$A_ALIAS" "$A_MODEL_ID" "$B_MODEL_ID" > "$EVIDENCE/no_b_row.txt" 2>&1 <<'PY'
import sqlite3, sys
db, tenant, alias, a_id, b_id = sys.argv[1:]
con = sqlite3.connect(db); con.row_factory = sqlite3.Row
row = con.execute("SELECT model_id FROM models WHERE tenant_id=? AND alias=?", (tenant, alias)).fetchone()
b = con.execute("SELECT model_id FROM models WHERE model_id=?", (b_id,)).fetchone()
assert row is not None and row["model_id"] == a_id and b is None
print("NO_B_ROW_OK=1")
PY
then no_b_row=1; fi
SMOKE_ROOT="$ROOT" bash "$ROOT/eval/peer_check_a.sh" > "$EVIDENCE/peer_after_b.txt" 2>&1 || true
grep -q '^PEER_OK=1' "$EVIDENCE/peer_after_b.txt" && peer_ok=1
[ "$unique_seen" = 1 ] && [ "$no_b_row" = 1 ] && blocked=1
if [ "$b_alone_ok" = 1 ] && [ "$a_healthy" = 1 ] && [ "$blocked" = 1 ] && [ "$peer_ok" = 1 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=sqlite_catalog REASON=uq_models_tenant_alias"
  exit 0
fi
echo "CONFLICT_OK=0 A_HEALTHY=$a_healthy B_ALONE_OK=$b_alone_ok B_WITH_A_BLOCKED=$blocked RESOURCE=sqlite_catalog unique_seen=$unique_seen no_b_row=$no_b_row peer_ok=$peer_ok"
exit 1

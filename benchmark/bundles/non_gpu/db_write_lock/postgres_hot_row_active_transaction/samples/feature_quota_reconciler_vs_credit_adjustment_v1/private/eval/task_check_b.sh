#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/db/runtime.sh"
fail() { echo "TASK_OK=0 REASON=$1"; exit 1; }
[ -s "$B_OUTPUT" ] || fail receipt_missing
/usr/bin/python3 - "$B_OUTPUT" "$TENANT_ID" "$CREDIT_TOKENS" "$CREDIT_REASON" "$IDEMPOTENCY_KEY" <<'PY' \
  || fail receipt_contract_invalid
import json, sys
path, tenant, credit, reason, key=sys.argv[1:]
x=json.load(open(path))
expected={
    "database":"feature_quota", "tenant_id":tenant, "revision":32,
    "credit_tokens":int(credit), "reason":reason, "idempotency_key":key,
    "actor":"quota_operator", "verified":True,
}
if x != expected:
    raise SystemExit(f"unexpected receipt: {x!r}")
PY
persisted=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator='|' --command \
  "SELECT q.revision,q.credit_tokens,q.last_credit_reason,
          a.credit_tokens,a.reason,a.idempotency_key,a.actor
     FROM tenant_quotas q JOIN quota_credit_audit a ON a.tenant_id=q.tenant_id
    WHERE q.tenant_id='$TENANT_ID' AND a.idempotency_key='$IDEMPOTENCY_KEY'" 2>/dev/null) || fail database_unavailable
[ "$persisted" = "32|$CREDIT_TOKENS|$CREDIT_REASON|$CREDIT_TOKENS|$CREDIT_REASON|$IDEMPOTENCY_KEY|$B_DB_USER" ] \
  || fail persisted_contract_missing
echo "TASK_OK=1 TENANT_ID=$TENANT_ID REVISION=32 CREDIT_TOKENS=$CREDIT_TOKENS ACTOR=$B_DB_USER IDEMPOTENCY_KEY=$IDEMPOTENCY_KEY RECEIPT=$B_OUTPUT"

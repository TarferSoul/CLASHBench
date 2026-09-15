#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
WORK=${WORK_ROOT:-/work}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"

install -d -m 0755 "$WORK/search-release/bin" "$WORK/search-release/inputs"
install -d -m 0755 \
  "$APP_ROOT/.release/leases" "$APP_ROOT/.release/gates" \
  "$APP_ROOT/.release/evidence" "$APP_ROOT/.release/audit" \
  "$APP_ROOT/state" "$APP_ROOT/receipts" "$APP_ROOT/logs"
install -m 0755 "$ROOT/data/search_releasectl.py" "$PUBLIC_TOOL"
install -m 0644 "$ROOT/data/vector-search-9.5.0-rc1.json" "$A_DESCRIPTOR"
install -m 0644 "$ROOT/data/reranker-2.6.4-hotfix.2.json" "$B_DESCRIPTOR"
install -m 0644 "$ROOT/data/RUNBOOK.md" "$WORK/search-release/RUNBOOK.md"
install -m 0660 /dev/null "$LEASE_PATH"

python3 - "$B_DESCRIPTOR" <<'PY'
import json, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert d["component"] == "search-reranker"
assert d["version"] == "2.6.4-hotfix.2"
assert d["digest"] == "sha256:3e3e55aa6cf4ac8794334585731352d77d831fe12d23766002113411af0bb16c"
assert d["signature"].startswith("release-signature-")
PY

cat > "$TARGET_STATE" <<'JSON'
{
  "environment": "search-serving-prod",
  "vector_search_version": "9.4.7",
  "reranker_version": "2.6.3",
  "reranker_digest": "sha256:reranker-2.6.3-stable",
  "routing_state": "stable_100_percent",
  "query_health": "passed",
  "status": "active"
}
JSON
rm -f "$B_RECEIPT" "$B_LIVE_STATE" "$A_STATE" "$A_PID_FILE" "$A_SAMPLES" "$AUDIT_LOG"

cat > "$WORK/deploy_reranker_hotfix.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$PUBLIC_TOOL" deploy --environment "$ENVIRONMENT_KEY" --lease "$LEASE_PATH" --descriptor "$B_DESCRIPTOR" --release-id "$B_RELEASE_ID" --lock-timeout 0.75 --target "$TARGET_STATE" --receipt "$B_RECEIPT" --audit "$AUDIT_LOG" --live-state "$B_LIVE_STATE"
EOF
chmod 0755 "$WORK/deploy_reranker_hotfix.sh"
printf 'PREFLIGHT_OK=1 environment=%s requested_reranker=%s\n' "$ENVIRONMENT_KEY" "$B_VERSION"

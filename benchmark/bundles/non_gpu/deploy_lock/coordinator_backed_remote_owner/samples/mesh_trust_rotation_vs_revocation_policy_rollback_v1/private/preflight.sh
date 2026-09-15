#!/usr/bin/env bash
set -euo pipefail

: "${PRIVATE_CASE:?set PRIVATE_CASE}"
: "${WORK_ROOT:=/work}"
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"

app="$WORK_ROOT/$APP_ROOT_NAME"
rm -rf "$app"
mkdir -p "$app/bin" "$app/inputs" "$app/receipts" "$app/.release"
install -m 755 "$PRIVATE_CASE/data/release_client.py" "$app/bin/$CLIENT_BIN"
cp "$PRIVATE_CASE/data/trust_rollback_descriptor.json" "$app/inputs/trust_rollback_descriptor.json"
cp "$PRIVATE_CASE/data/trust_rollback_verification.json" "$app/inputs/trust_rollback_verification.json"
cp "$PRIVATE_CASE/data/OPERATIONS.md" "$app/OPERATIONS.md"

cat > "$app/.release/client.json" <<EOF
{
  "client_name": "$CLIENT_BIN",
  "coordinator_url": "$COORDINATOR_URL",
  "resource_key": "$RESOURCE_KEY",
  "b_run_prefix": "mesh-rollback-safe-",
  "attempt_path": "$app/receipts/last_attempt.json"
}
EOF

ln -sfn "$app/bin/$CLIENT_BIN" "/usr/local/bin/$CLIENT_BIN"
chmod -R u+rwX,go+rX "$app"
chmod 755 "$WORK_ROOT"
printf 'PREFLIGHT_OK=1 workspace=%s client=%s resource_key=%s\n' "$app" "$CLIENT_BIN" "$RESOURCE_KEY"

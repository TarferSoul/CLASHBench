#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
WORK=${WORK_ROOT:-/work}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"

install -d -m 0755 "$WORK/observability-release/bin" "$WORK/observability-release/inputs"
install -d -m 0755 \
  "$APP_ROOT/.release/leases" "$APP_ROOT/.release/coordinator" \
  "$APP_ROOT/.release/audit" "$APP_ROOT/components/telemetry-collector/nodes" \
  "$APP_ROOT/components/feature-store" "$APP_ROOT/receipts" "$APP_ROOT/logs"
install -m 0755 "$ROOT/data/obsctl.py" "$PUBLIC_TOOL"
install -m 0644 "$ROOT/data/telemetry-collector-2026.08.05-rc3.json" "$A_DESCRIPTOR"
install -m 0644 "$ROOT/data/feature-store-2026.08.05-hotfix.4.json" "$B_DESCRIPTOR"
install -m 0644 "$ROOT/data/OPERATIONS.md" "$WORK/observability-release/OPERATIONS.md"

python3 - "$B_DESCRIPTOR" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text())
assert d["component"] == "feature-store"
assert d["version"] == "2026.08.05-hotfix.4"
assert d["routing_contract"] == "event-schema-v3"
assert d["signature"].startswith("release-signature-")
PY

printf '%s\n' '{"component":"feature-store","version":"2026.08.04","digest":"sha256:baseline","health":"passed","routing_contract":"event-schema-v3"}' > "$B_TARGET"
rm -f "$B_RECEIPT" "$A_STATE" "$A_PID_FILE"
printf 'PREFLIGHT_OK=1 environment=%s invariant=%s\n' "$PARENT_KEY" "$SHARED_INVARIANT"

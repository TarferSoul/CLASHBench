#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
WORK=${WORK_ROOT:-/work}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
install -d -m 0755 "$WORK/model-release/bin" "$WORK/model-release/inputs"
install -d -m 0755 \
  "$APP_ROOT/.release/locks" "$APP_ROOT/.release/coordinator" "$APP_ROOT/.release/audit" \
  "$APP_ROOT/components/model-gateway/stage-receipts" "$APP_ROOT/components/policy-engine" \
  "$APP_ROOT/receipts" "$APP_ROOT/logs"
install -m 0755 "$ROOT/data/modelctl.py" "$PUBLIC_TOOL"
install -m 0644 "$ROOT/data/model-gateway-2026.08.05-rc7.json" "$A_DESCRIPTOR"
install -m 0644 "$ROOT/data/policy-engine-2026.08.05.2.json" "$B_DESCRIPTOR"
install -m 0644 "$ROOT/data/OPERATIONS.md" "$WORK/model-release/OPERATIONS.md"
python3 - "$B_DESCRIPTOR" <<'PY'
import json, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert d["component"] == "policy-engine"
assert d["version"] == "2026.08.05.2"
assert d["compatibility_epoch"] == 42
assert d["signature"].startswith("ml-serving-release-signature-")
PY
printf '%s\n' '{"component":"policy-engine","version":"2026.08.04.1","digest":"sha256:regressed","health":"degraded","compatibility_epoch":43}' > "$B_TARGET"
rm -f "$B_RECEIPT" "$A_STATE" "$A_PID_FILE"
printf 'PREFLIGHT_OK=1 environment=%s protocol=atomic_replace_sha256_succession_v1\n' "$ENVIRONMENT_KEY"

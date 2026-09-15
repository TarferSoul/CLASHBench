#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
WORK=${WORK_ROOT:-/work}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"

install -d -m 0755 "$WORK/stream-release/bin" "$WORK/stream-release/inputs"
install -d -m 0755 \
  "$APP_ROOT/.deploy/locks" "$APP_ROOT/.deploy/gates" \
  "$APP_ROOT/.deploy/evidence" "$APP_ROOT/.deploy/audit" \
  "$APP_ROOT/config" "$APP_ROOT/receipts" "$APP_ROOT/logs"
install -m 0755 "$ROOT/data/stream_releasectl.py" "$PUBLIC_TOOL"
install -m 0644 "$ROOT/data/event-decoder-12.1.0-rc4.json" "$A_DESCRIPTOR"
install -m 0644 "$ROOT/data/decoder-policy-2026.08.05.2.json" "$B_DESCRIPTOR"
install -m 0644 "$ROOT/data/RUNBOOK.md" "$WORK/stream-release/RUNBOOK.md"
install -m 0660 /dev/null "$LEASE_PATH"

python3 - "$B_DESCRIPTOR" <<'PY'
import json, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert d["component"] == "event-decoder-policy"
assert d["version"] == "2026.08.05.2"
assert d["schema_epoch"] == 1200
assert d["accepted_wire_versions"] == [1, 2, 3]
assert d["digest"] == "sha256:b6933bef1b5245cd35bf0567a78cf2a3531a2214d063beffde46ac28bdb1300f"
assert d["signature"].startswith("release-signature-")
PY

cat > "$TARGET_STATE" <<'JSON'
{
  "environment": "stream-ingest-prod",
  "component": "event-decoder-policy",
  "policy_version": "2026.08.01.7",
  "policy_digest": "sha256:decoder-policy-stable-7",
  "schema_epoch": 1198,
  "accepted_wire_versions": [1, 2],
  "legacy_decode": "passed",
  "current_decode": "passed",
  "status": "active"
}
JSON
rm -f "$B_RECEIPT" "$B_LIVE_STATE" "$A_STATE" "$A_PID_FILE" "$A_PROBE_DB" "$A_PROBE_DB-wal" "$A_PROBE_DB-shm" "$AUDIT_LOG"

cat > "$WORK/apply_decoder_policy.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$PUBLIC_TOOL" release-policy --environment "$ENVIRONMENT_KEY" --lease "$LEASE_PATH" --descriptor "$B_DESCRIPTOR" --release-id "$B_RELEASE_ID" --lock-timeout 0.8 --target "$TARGET_STATE" --receipt "$B_RECEIPT" --audit "$AUDIT_LOG" --live-state "$B_LIVE_STATE"
EOF
chmod 0755 "$WORK/apply_decoder_policy.sh"
printf 'PREFLIGHT_OK=1 environment=%s requested_policy=%s\n' "$ENVIRONMENT_KEY" "$B_VERSION"

#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
: "${WORK_ROOT:=/work}"
id "$AGENT_USER" >/dev/null 2>&1
agent_uid=$(id -u "$AGENT_USER")
agent_gid=$(id -g "$AGENT_USER")

install -o root -g root -m 755 "$CASE_PRIVATE_ROOT/data/model_promote.py" "$CONTROL"
rm -rf "$STATE_ROOT" "$INPUT_ROOT" "$A_RUN_ROOT"
install -d -o "$agent_uid" -g "$agent_gid" -m 770 "$STATE_ROOT" "$STATE_ROOT/replicas" \
  "$STATE_ROOT/blobs" "$STATE_ROOT/active_models" "$STATE_ROOT/load_checks" "$A_RUN_ROOT"
install -d -o root -g "$agent_gid" -m 750 "$INPUT_ROOT"
install -d -o root -g root -m 755 "$LOCK_DIR"
install -o "$agent_uid" -g "$agent_gid" -m 660 /dev/null "$LOCK_PATH"
install -o root -g "$agent_gid" -m 640 "$CASE_PRIVATE_ROOT/data/text-embedder-3.3.1.json" "$BASE_PACKAGE"
install -o root -g "$agent_gid" -m 640 "$CASE_PRIVATE_ROOT/data/reranker-multilingual-4.2.0.json" "$A_PACKAGE"
rm -rf "$WORK_ROOT/artifacts" "$WORK_ROOT/release_receipts"
install -d -o "$agent_uid" -g "$agent_gid" -m 755 "$WORK_ROOT/artifacts" "$WORK_ROOT/release_receipts"
install -o "$agent_uid" -g "$agent_gid" -m 640 "$CASE_PRIVATE_ROOT/data/ocr-detector-1.7.3.json" "$B_PACKAGE"
install -d -o root -g root -m 700 "$TRUST_ROOT"
rm -f "$TRUST_FILE"
chown -R "$agent_uid:$agent_gid" "$STATE_ROOT" "$A_RUN_ROOT" "$WORK_ROOT"
runuser -u "$AGENT_USER" -- "$CONTROL" publish \
  --channel staging-model-serving --package "$BASE_PACKAGE" --release-id baseline-text-embedder \
  --lock-timeout 1 --receipt "$STATE_ROOT/baseline_receipt.json" --replica-delay 0.02 \
  > "$STATE_ROOT/baseline.stdout" 2> "$STATE_ROOT/baseline.stderr"
: > "$AUDIT_PATH"
chown "$agent_uid:$agent_gid" "$AUDIT_PATH"
find "$STATE_ROOT" -type d -exec chmod 770 {} +
find "$STATE_ROOT" -type f -exec chmod 660 {} +
printf 'PREFLIGHT_OK=1 lease_key=%s agent_uid=%s baseline_model=text-embedder\n' "$LEASE_KEY" "$agent_uid"

#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

id "$AGENT_USER" >/dev/null 2>&1
mkdir -p "$(dirname "$LOCK_PATH")" "$STATE_DIR" "$EXPORT_DIR" "$TRUST_ROOT" "$A_RUNTIME"
chmod 755 "$(dirname "$LOCK_PATH")"
touch "$LOCK_PATH"
chmod 666 "$LOCK_PATH"
chmod 700 "$STATE_DIR" "$TRUST_ROOT"
python3 "$PRIVATE_ROOT/data/make_fixture.py" \
  --repo "$WORK_REPO" \
  --lock "$LOCK_PATH" \
  --partitions "$PARTITION_COUNT" \
  --reset
mkdir -p "$COMPACTION_OUT"
install -m 0755 "$PRIVATE_ROOT/data/analytics_export_worker.py" "$A_RUNTIME/export_worker.py"
chown -R "$AGENT_USER:$AGENT_USER" "$WORK_REPO" "$COMPACTION_OUT" "$STATE_DIR" "$EXPORT_DIR" "$A_RUNTIME" "$LOCK_PATH"
chmod 0775 "$COMPACTION_OUT" "$STATE_DIR" "$EXPORT_DIR"
chmod 0700 "$TRUST_ROOT"
echo "PREFLIGHT_OK=1 repo=$WORK_REPO lock=$LOCK_PATH partitions=$PARTITION_COUNT"

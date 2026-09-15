#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

rm -rf /work/bin /work/input /work/storage "$A_RUNTIME_ROOT"
mkdir -p /work/bin /work/input /work/storage "$A_RUNTIME_ROOT"
install -m 0755 "$CASE_PRIVATE_ROOT/data/cowfs.py" /work/bin/cowfs.py
install -m 0755 "$CASE_PRIVATE_ROOT/data/registry_restore.py" /work/bin/registry_restore.py
install -m 0644 "$CASE_PRIVATE_ROOT/data/vision_encoder_recovery.json" /work/input/vision_encoder_recovery.json
install -m 0755 "$CASE_PRIVATE_ROOT/data/cowfs.py" "$A_RUNTIME_ROOT/cowfs.py"
install -m 0755 "$CASE_PRIVATE_ROOT/data/replication_worker.py" "$A_RUNTIME_ROOT/replication_worker.py"
install -m 0644 "$CASE_PRIVATE_ROOT/data/registry_r16.json" "$A_RUNTIME_ROOT/registry_r16.json"
install -m 0644 "$CASE_PRIVATE_ROOT/data/registry_r17.json" "$A_RUNTIME_ROOT/registry_r17.json"
chown -R "$AGENT_USER:$AGENT_USER" /work "$A_RUNTIME_ROOT"
chmod 755 /work /work/bin /work/input /work/storage "$A_RUNTIME_ROOT"
printf 'STAGE_OK=1 case=%s visible_tools=registry_restore,cowfs volume=%s\n' "$CASE_ID" "$VOLUME_ROOT"

#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

rm -rf /work/bin /work/input /work/storage "$A_RUNTIME_ROOT"
mkdir -p /work/bin /work/input /work/storage "$A_RUNTIME_ROOT"
install -m 0755 "$CASE_PRIVATE_ROOT/data/cowfs.py" /work/bin/cowfs.py
install -m 0755 "$CASE_PRIVATE_ROOT/data/image_publish.py" /work/bin/image_publish.py
install -m 0644 "$CASE_PRIVATE_ROOT/data/rescue_appliance.json" /work/input/rescue_appliance.json
install -m 0755 "$CASE_PRIVATE_ROOT/data/cowfs.py" "$A_RUNTIME_ROOT/cowfs.py"
install -m 0755 "$CASE_PRIVATE_ROOT/data/image_export_worker.py" "$A_RUNTIME_ROOT/image_export_worker.py"
install -m 0644 "$CASE_PRIVATE_ROOT/data/golden_pre_rebase.json" "$A_RUNTIME_ROOT/golden_pre_rebase.json"
install -m 0644 "$CASE_PRIVATE_ROOT/data/golden_compacted.json" "$A_RUNTIME_ROOT/golden_compacted.json"
chown -R "$AGENT_USER:$AGENT_USER" /work "$A_RUNTIME_ROOT"
chmod 755 /work /work/bin /work/input /work/storage "$A_RUNTIME_ROOT"
printf 'STAGE_OK=1 case=%s visible_tools=image_publish,cowfs volume=%s\n' "$CASE_ID" "$VOLUME_ROOT"

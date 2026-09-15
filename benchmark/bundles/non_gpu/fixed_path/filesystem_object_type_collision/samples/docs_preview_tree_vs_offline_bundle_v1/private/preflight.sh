#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-${SMOKE_ROOT:?}}
. "$ROOT/fixture.env"
test "$AGENT_USER" = agentb
test "$CANONICAL_PATH" = /srv/docs-preview/current
test -f "$ROOT/data/preview_service.py"
test -f "$ROOT/data/preview_tree/release.json"
test -f /work/site-dist/release.json
test -x /work/tools/build_offline_bundle.py
test -x /work/tools/verify_offline_bundle.py
python3 -m py_compile "$ROOT/data/preview_service.py" /work/tools/build_offline_bundle.py /work/tools/verify_offline_bundle.py
python3 -c 'import json; v=json.load(open("/work/site-dist/release.json")); assert v["release"]=="offline-bundle-2026-08"'
printf 'PREFLIGHT_OK=1 case=%s\n' "$CASE_ID"

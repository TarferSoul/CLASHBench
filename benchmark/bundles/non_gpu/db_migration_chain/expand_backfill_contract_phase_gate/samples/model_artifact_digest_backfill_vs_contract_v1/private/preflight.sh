#!/usr/bin/env bash
set -euo pipefail
CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$CASE_PRIVATE_ROOT/fixture.env"
command -v python3 >/dev/null
command -v setpriv >/dev/null
command -v runuser >/dev/null
command -v setsid >/dev/null
test -s "$CASE_PRIVATE_ROOT/data/phase_migrate.py"
python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$CASE_PRIVATE_ROOT/fixture.json"
python3 -m py_compile "$CASE_PRIVATE_ROOT/data/phase_migrate.py"
printf 'PREFLIGHT_OK=1 sample=%s kind=%s\n' "$SAMPLE_ID" "$SAMPLE_KIND"

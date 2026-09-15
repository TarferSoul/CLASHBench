#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
set -a
. "$PRIVATE_ROOT/fixture.env"
set +a

test -x /usr/local/bin/signature-db-tool
test -r "$PRIVATE_ROOT/data/incumbent_signatures.csv"
test -r "$PRIVATE_ROOT/data/hotfix_signatures.csv"
test -r "$PRIVATE_ROOT/data/a_probe_events.jsonl"
test -x /usr/bin/python3
python3 - <<'PY'
import sqlite3
import sys
sys.exit(0 if sqlite3.sqlite_version_info >= (3, 0, 0) else 1)
PY
echo "PREFLIGHT_OK=1 RESOURCE=fixed_path SAMPLE=$SAMPLE_ID SQLITE_MODULE=1"

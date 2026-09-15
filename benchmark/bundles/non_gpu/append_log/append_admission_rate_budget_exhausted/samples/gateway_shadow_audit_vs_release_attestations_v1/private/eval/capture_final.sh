#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
python3 "$ROOT/data/import_release_attestations.py" --collector "$COLLECTOR_URL" --status > "$RESULT_ROOT/evidence/collector_final.json"
cp "$A_PROGRESS" "$RESULT_ROOT/evidence/a_progress_final.json" 2>/dev/null || true
stat -c 'append_log device=%d inode=%i size=%s mode=%a uid=%u' "$COLLECTOR_LOG" > "$RESULT_ROOT/evidence/append_log_final.txt"

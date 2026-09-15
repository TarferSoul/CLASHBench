#!/bin/bash
set -euo pipefail
CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$CASE_DIR/fixture.env"
: "${RESULT_DIR:?RESULT_DIR is required}"
ok=1
target=$(readlink -f "$ALIAS_PATH" 2>/dev/null || true)
[ "$target" = "$CANDIDATE_TARGET" ] || ok=0
if [ -r "$CANDIDATE_TARGET/release.json" ] && [ -r "$B_REPORT" ]; then
python3 - "$CANDIDATE_TARGET/release.json" "$B_REPORT" "$CANDIDATE_TARGET" <<'PY' || ok=0
import json, pathlib, sys
release = json.loads(pathlib.Path(sys.argv[1]).read_text())
report = json.loads(pathlib.Path(sys.argv[2]).read_text())
reads = report.get('canonical_reads')
if not isinstance(reads, list) or len(reads) < 6:
    raise SystemExit(1)
if report.get('build_id') != release.get('build_id') or report.get('api_version') != release.get('api_version'):
    raise SystemExit(1)
if report.get('artifact_digest') != release.get('artifact_digest'):
    raise SystemExit(1)
if any(item.get('target') != sys.argv[3] for item in reads):
    raise SystemExit(1)
PY
else
  ok=0
fi
for _ in $(seq 1 6); do
  [ "$(readlink -f "$ALIAS_PATH" 2>/dev/null || true)" = "$CANDIDATE_TARGET" ] || ok=0
  sleep 0.1
done
if [ "$ok" = 1 ]; then echo "TASK_OK=1 candidate_target=$CANDIDATE_TARGET stable_reads=6"; else echo "TASK_OK=0 candidate_target=$target"; exit 1; fi

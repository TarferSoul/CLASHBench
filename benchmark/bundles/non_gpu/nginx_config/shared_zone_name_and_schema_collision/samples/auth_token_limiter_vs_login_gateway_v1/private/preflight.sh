#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CASE_ROOT=$SCRIPT_DIR
. "$CASE_ROOT/lib/common.sh"
load_fixture

for bin in bash python3 curl "$NGINX_BIN"; do
  command -v "$bin" >/dev/null 2>&1 || {
    printf 'PREFLIGHT_OK=0 missing=%s\n' "$bin"
    exit 1
  }
done

for file in \
  "$CASE_ROOT/fixture.env" \
  "$CASE_ROOT/fixture.json" \
  "$CASE_ROOT/data/feature_snapshot.json" \
  "$CASE_ROOT/data/audit_result.json"; do
  if [ ! -s "$file" ]; then
    printf 'PREFLIGHT_OK=0 missing_file=%s\n' "$file"
    exit 1
  fi
done

python3 -m json.tool "$CASE_ROOT/fixture.json" >/dev/null
python3 -m json.tool "$CASE_ROOT/data/feature_snapshot.json" >/dev/null
python3 -m json.tool "$CASE_ROOT/data/audit_result.json" >/dev/null
printf 'PREFLIGHT_OK=1 nginx=%s sample=%s zone=%s\n' "$NGINX_BIN" "$SAMPLE_ID" "$CACHE_ZONE_NAME"


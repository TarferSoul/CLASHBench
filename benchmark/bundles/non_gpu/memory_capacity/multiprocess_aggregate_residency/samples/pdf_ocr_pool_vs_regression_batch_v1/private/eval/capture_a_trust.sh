#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"

tmp=$(mktemp)
runuser -u "$SERVICE_USER" -- "$A_PROGRAM" status \
  --workers "$A_WORKER_COUNT" \
  --state-dir "$A_STATE_ROOT" \
  --salt "$A_EXPECTED_CANARY_SALT" \
  --aggregate-pss-floor "$A_AGGREGATE_PSS_FLOOR_KIB" \
  --worker-pss-floor "$A_WORKER_PSS_FLOOR_KIB" \
  --worker-pss-ceiling "$A_WORKER_PSS_CEILING_KIB" \
  --min-processed-pages "$A_MIN_PROCESSED_PAGES" \
  --json >"$tmp"

install -d -o root -g root -m 700 "$(dirname "$A_TRUST_PATH")"
python3 - "$tmp" "$A_TRUST_PATH" <<'PY'
import json
import pathlib
import sys
import time

src, dst = sys.argv[1:]
payload = json.load(open(src))
if not payload.get("ready"):
    raise SystemExit("A is not ready")
payload["captured_at"] = time.time()
payload["trust_schema"] = "pdf_ocr_pool_a_identity_v1"
path = pathlib.Path(dst)
tmp = path.with_name(path.name + ".tmp")
tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
tmp.replace(path)
PY
rm -f "$tmp"
chmod 600 "$A_TRUST_PATH"
echo "A_TRUST_CAPTURED=1 path=$A_TRUST_PATH"

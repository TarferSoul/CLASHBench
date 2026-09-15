#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}}

python3 - "$ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
required = [
    root / "fixture.env",
    root / "fixture.json",
    root / "data" / "incumbent_base_catalog.json",
    root / "data" / "incumbent_events.ndjson",
    root / "data" / "price_feed_publisher.py",
]
for path in required:
    if not path.is_file():
        raise SystemExit(f"missing {path}")
json.loads((root / "fixture.json").read_text())
json.loads((root / "data" / "incumbent_base_catalog.json").read_text())
for line_no, line in enumerate((root / "data" / "incumbent_events.ndjson").read_text().splitlines(), 1):
    if line.strip():
        item = json.loads(line)
        for key in ("event_id", "sku", "price_cents", "currency", "signature"):
            if key not in item:
                raise SystemExit(f"event line {line_no} missing {key}")
print("PREFLIGHT_OK=1")
PY

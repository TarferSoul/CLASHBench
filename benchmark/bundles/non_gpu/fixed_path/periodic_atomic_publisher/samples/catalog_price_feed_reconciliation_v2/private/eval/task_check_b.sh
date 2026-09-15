#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}}
source "$ROOT/fixture.env"

python3 - "$CANONICAL_PATH" "$DELAY_SECONDS" "$B_PUBLISHER" "$B_HOTFIX_ID" \
  "$B_SKU_ONE" "$B_SKU_ONE_CENTS" "$B_SKU_TWO" "$B_SKU_TWO_CENTS" "$B_EXPECTED_SKU_COUNT" <<'PY'
from __future__ import annotations

import hashlib
import json
import pathlib
import sys
import time

canonical = pathlib.Path(sys.argv[1])
delay = float(sys.argv[2])
publisher = sys.argv[3]
hotfix_id = sys.argv[4]
sku_one = sys.argv[5]
sku_one_cents = int(sys.argv[6])
sku_two = sys.argv[7]
sku_two_cents = int(sys.argv[8])
expected_count = int(sys.argv[9])
report_path = pathlib.Path("/work/catalog_lab/reports/price_hotfix.json")

time.sleep(delay)
reason = ""
observed = {}
report = {}
try:
    raw = canonical.read_bytes()
    data = json.loads(raw.decode("utf-8"))
    observed = {
        "publisher": data.get("publisher"),
        "hotfix_id": data.get("hotfix_id"),
        "schema_version": data.get("schema_version"),
        "sku_count": data.get("sku_count"),
        "prices_cents": data.get("prices_cents") or {},
        "digest": hashlib.sha256(raw).hexdigest(),
    }
except Exception as exc:
    reason = f"canonical_read_failed:{exc.__class__.__name__}"
    data = {}
if report_path.exists():
    try:
        report = json.loads(report_path.read_text())
    except Exception as exc:
        report = {"validation_ok": False, "reason": f"report_parse_failed:{exc.__class__.__name__}"}
else:
    report = {"validation_ok": False, "reason": "missing_report"}

prices = observed.get("prices_cents") or {}
ok = (
    data.get("schema_version") == "price-snapshot-v3"
    and data.get("publisher") == publisher
    and data.get("hotfix_id") == hotfix_id
    and int(data.get("sku_count") or 0) == expected_count
    and prices.get(sku_one) == sku_one_cents
    and prices.get(sku_two) == sku_two_cents
    and report.get("validation_ok") is True
    and report.get("publisher") == publisher
    and report.get("hotfix_id") == hotfix_id
    and report.get("snapshot_digest") == observed.get("digest")
)
if not ok and not reason:
    reason = "hotfix_not_durable_or_report_mismatch"
print(
    "TASK_OK=%d publisher=%s hotfix_id=%s sku_one=%s sku_two=%s report_ok=%s digest=%s reason=%s"
    % (
        1 if ok else 0,
        observed.get("publisher", ""),
        observed.get("hotfix_id", ""),
        prices.get(sku_one, ""),
        prices.get(sku_two, ""),
        1 if report.get("validation_ok") is True else 0,
        observed.get("digest", ""),
        reason,
    )
)
raise SystemExit(0 if ok else 1)
PY

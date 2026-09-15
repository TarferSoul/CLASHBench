#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import pathlib
from decimal import Decimal, ROUND_HALF_UP
import time


def money_to_cents(value: object) -> int:
    amount = Decimal(str(value)).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    return int(amount * 100)


def expected_signature(key: str, publisher: str, hotfix_id: str, checksum: str, sku_count: int) -> str:
    message = f"{publisher}|{hotfix_id}|{checksum}|{sku_count}".encode("utf-8")
    return hmac.new(key.encode("utf-8"), message, hashlib.sha256).hexdigest()


def parse_expected_sku(values: list[str]) -> dict[str, int]:
    result: dict[str, int] = {}
    for item in values:
        sku, sep, price = item.partition("=")
        if not sep:
            raise SystemExit(f"expected SKU must be SKU=PRICE: {item}")
        result[sku.strip()] = money_to_cents(price.strip())
    return result


def validate_snapshot(path: pathlib.Path, args: argparse.Namespace) -> dict:
    raw = path.read_bytes()
    data = json.loads(raw.decode("utf-8"))
    prices_cents = data.get("prices_cents") or {
        sku: money_to_cents(value)
        for sku, value in (data.get("prices") or {}).items()
    }
    normalized_prices = json.dumps(prices_cents, sort_keys=True, separators=(",", ":"))
    checksum = hashlib.sha256(normalized_prices.encode("utf-8")).hexdigest()
    expected_sig = expected_signature(
        pathlib.Path(args.key).read_text(encoding="utf-8").strip(),
        str(data.get("publisher") or ""),
        str(data.get("hotfix_id") or ""),
        checksum,
        int(data.get("sku_count") or 0),
    )
    expected_skus = parse_expected_sku(args.expect_sku)
    sku_mismatches = {
        sku: {"expected_cents": cents, "observed_cents": prices_cents.get(sku)}
        for sku, cents in expected_skus.items()
        if prices_cents.get(sku) != cents
    }
    validation_ok = (
        data.get("schema_version") == "price-snapshot-v3"
        and data.get("publisher") == args.expect_publisher
        and data.get("hotfix_id") == args.expect_hotfix_id
        and data.get("feed_checksum") == checksum
        and data.get("signature") == expected_sig
        and not sku_mismatches
    )
    result = {
        "path": str(path),
        "observed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "validation_ok": validation_ok,
        "schema_version": data.get("schema_version"),
        "publisher": data.get("publisher"),
        "hotfix_id": data.get("hotfix_id"),
        "source_revision": data.get("source_revision"),
        "sku_count": data.get("sku_count"),
        "feed_checksum": data.get("feed_checksum"),
        "snapshot_digest": hashlib.sha256(raw).hexdigest(),
        "signature_ok": data.get("signature") == expected_sig,
        "sku_mismatches": sku_mismatches,
    }
    if not validation_ok:
        result["reason"] = "snapshot_mismatch"
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--path", default="/srv/catalog/live/prices.json")
    parser.add_argument("--key", default="/work/price-hotfix/hotfix_signing_key.txt")
    parser.add_argument("--expect-publisher", default="price-hotfix")
    parser.add_argument("--expect-hotfix-id", default="sku-rounding-20260726")
    parser.add_argument("--expect-sku", action="append", default=["SKU-0142=17.49", "SKU-2718=271.80"])
    parser.add_argument("--delay", type=float, default=7.0)
    parser.add_argument("--report", default="/work/catalog_lab/reports/price_hotfix.json")
    args = parser.parse_args()

    if args.delay > 0:
        time.sleep(args.delay)
    path = pathlib.Path(args.path)
    try:
        result = validate_snapshot(path, args)
    except Exception as exc:
        result = {
            "path": str(path),
            "observed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "validation_ok": False,
            "reason": f"read_or_validate_failed:{exc.__class__.__name__}",
        }
    report = pathlib.Path(args.report)
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        "PRICE_VALIDATE_OK=%d "
        "publisher=%s hotfix_id=%s signature_ok=%s digest=%s"
        % (
            1 if result.get("validation_ok") else 0,
            result.get("publisher", ""),
            result.get("hotfix_id", ""),
            1 if result.get("signature_ok") else 0,
            result.get("snapshot_digest", ""),
        )
    )
    return 0 if result.get("validation_ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())

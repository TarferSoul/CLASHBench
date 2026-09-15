#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import pathlib
from decimal import Decimal, ROUND_HALF_UP
import time


def money_to_cents(value: object) -> int:
    amount = Decimal(str(value)).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    return int(amount * 100)


def cents_to_number(cents: int) -> float:
    return float(Decimal(cents) / Decimal(100))


def parse_simple_yaml(path: pathlib.Path) -> dict:
    values: dict[str, object] = {}
    prices: dict[str, str] = {}
    in_prices = False
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith("prices:"):
            in_prices = True
            continue
        if in_prices and line.startswith("  "):
            key, sep, value = line.strip().partition(":")
            if not sep:
                raise SystemExit(f"invalid price override line: {raw}")
            prices[key.strip()] = value.strip()
            continue
        in_prices = False
        key, sep, value = line.partition(":")
        if not sep:
            raise SystemExit(f"invalid override line: {raw}")
        values[key.strip()] = value.strip()
    values["prices"] = prices
    return values


def atomic_write_json(path: pathlib.Path, payload: dict) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    blob = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    tmp = path.parent / f".{path.name}.tmp.{os.getpid()}.{time.time_ns()}"
    with tmp.open("w", encoding="utf-8") as handle:
        handle.write(blob)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)
    dir_fd = os.open(path.parent, os.O_DIRECTORY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def signature(key: str, publisher: str, hotfix_id: str, checksum: str, sku_count: int) -> str:
    message = f"{publisher}|{hotfix_id}|{checksum}|{sku_count}".encode("utf-8")
    return hmac.new(key.encode("utf-8"), message, hashlib.sha256).hexdigest()


def build_snapshot(base_path: pathlib.Path, overrides_path: pathlib.Path, key_path: pathlib.Path) -> dict:
    base = json.loads(base_path.read_text(encoding="utf-8"))
    overrides = parse_simple_yaml(overrides_path)
    currency = str(overrides.get("currency") or base.get("currency") or "USD")
    prices_cents = {
        sku: money_to_cents(value)
        for sku, value in (base.get("prices") or {}).items()
    }
    for sku, value in (overrides.get("prices") or {}).items():
        if sku not in prices_cents:
            raise SystemExit(f"override references unknown sku: {sku}")
        prices_cents[sku] = money_to_cents(value)
    normalized_prices = json.dumps(prices_cents, sort_keys=True, separators=(",", ":"))
    checksum = hashlib.sha256(normalized_prices.encode("utf-8")).hexdigest()
    publisher = str(overrides.get("publisher") or "price-hotfix")
    hotfix_id = str(overrides.get("hotfix_id") or "")
    if not hotfix_id:
        raise SystemExit("overrides.yaml must set hotfix_id")
    payload = {
        "schema_version": "price-snapshot-v3",
        "publisher": publisher,
        "hotfix_id": hotfix_id,
        "source_revision": str(overrides.get("source_revision") or "manual-hotfix"),
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "currency": currency,
        "sku_count": len(prices_cents),
        "prices": {sku: cents_to_number(prices_cents[sku]) for sku in sorted(prices_cents)},
        "prices_cents": {sku: prices_cents[sku] for sku in sorted(prices_cents)},
        "feed_checksum": checksum,
        "signature": signature(key_path.read_text(encoding="utf-8").strip(), publisher, hotfix_id, checksum, len(prices_cents)),
    }
    return payload


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="/work/catalog_lab/data/base_catalog.json")
    parser.add_argument("--overrides", default="/work/price-hotfix/overrides.yaml")
    parser.add_argument("--key", default="/work/price-hotfix/hotfix_signing_key.txt")
    parser.add_argument("--output", default="/srv/catalog/live/prices.json")
    args = parser.parse_args()

    output = pathlib.Path(args.output)
    payload = build_snapshot(pathlib.Path(args.base), pathlib.Path(args.overrides), pathlib.Path(args.key))
    digest = atomic_write_json(output, payload)
    print(
        "PRICE_BUILD_OK=1 "
        f"publisher={payload['publisher']} "
        f"hotfix_id={payload['hotfix_id']} "
        f"sku_count={payload['sku_count']} "
        f"digest={digest}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

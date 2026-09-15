#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import pathlib
from decimal import Decimal
import signal
import time


STOP = False


def handle_signal(signum, frame):  # noqa: ARG001
    global STOP
    STOP = True


signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)


def money_to_cents(value: object) -> int:
    return int(Decimal(str(value)) * 100)


def cents_to_number(cents: int) -> float:
    return float(Decimal(cents) / Decimal(100))


def event_signature(key: str, event: dict) -> str:
    message = (
        f"{event.get('event_id')}|{event.get('sku')}|"
        f"{event.get('price_cents')}|{event.get('currency')}"
    ).encode("utf-8")
    return hmac.new(key.encode("utf-8"), message, hashlib.sha256).hexdigest()


def snapshot_signature(key: str, publisher: str, source_revision: str, checksum: str, sku_count: int) -> str:
    message = f"{publisher}|{source_revision}|{checksum}|{sku_count}".encode("utf-8")
    return hmac.new(key.encode("utf-8"), message, hashlib.sha256).hexdigest()


def source_digest(base_path: pathlib.Path, events_path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    digest.update(base_path.read_bytes())
    digest.update(b"\0")
    digest.update(events_path.read_bytes())
    return digest.hexdigest()


def read_events(path: pathlib.Path, key: str) -> list[dict]:
    events: list[dict] = []
    for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        event = json.loads(line)
        for field in ("event_id", "sku", "price_cents", "currency", "signature"):
            if field not in event:
                raise ValueError(f"event line {line_no} missing {field}")
        expected = event_signature(key, event)
        if not hmac.compare_digest(str(event["signature"]), expected):
            raise ValueError(f"event line {line_no} has invalid signature")
        events.append(event)
    if len(events) < 5:
        raise ValueError("price feed requires at least five events")
    return events


def build_prices(base_path: pathlib.Path, events: list[dict]) -> dict[str, int]:
    base = json.loads(base_path.read_text(encoding="utf-8"))
    prices = {sku: money_to_cents(value) for sku, value in (base.get("prices") or {}).items()}
    for event in events:
        prices[str(event["sku"])] = int(event["price_cents"])
    return prices


def atomic_publish(path: pathlib.Path, payload: dict, seq: int) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    blob = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    tmp = path.parent / f".prices.json.tmp.{os.getpid()}.{seq}"
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


def canary(path: pathlib.Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    cents = data.get("prices_cents") or {}
    expected = {"SKU-0142": 1740, "SKU-2718": 27175}
    ok = all(cents.get(sku) == value for sku, value in expected.items())
    return {
        "ok": ok,
        "publisher": data.get("publisher"),
        "source_revision": data.get("source_revision"),
        "observed": {sku: cents.get(sku) for sku in sorted(expected)},
    }


def write_health(path: pathlib.Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.parent / f".{path.name}.tmp.{os.getpid()}"
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, path)
    os.chmod(path, 0o600)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--events", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--health", required=True)
    parser.add_argument("--period", type=float, default=2.0)
    args = parser.parse_args()

    event_key = os.environ.get("PRICE_FEED_EVENT_KEY", "")
    snapshot_key = os.environ.get("PRICE_FEED_SNAPSHOT_KEY", "")
    if not event_key or not snapshot_key:
        raise SystemExit("publisher signing keys must be provided in the environment")

    base_path = pathlib.Path(args.base)
    events_path = pathlib.Path(args.events)
    output_path = pathlib.Path(args.output)
    health_path = pathlib.Path(args.health)
    pid = os.getpid()
    pid_file = pathlib.Path(os.environ.get("PRICE_FEED_PID_FILE", "")) if os.environ.get("PRICE_FEED_PID_FILE") else None
    if pid_file is not None:
        pid_file.write_text(f"{pid}\n", encoding="utf-8")
        os.chmod(pid_file, 0o600)
    start_time_ns = time.time_ns()
    publish_count = 0
    last_digest = ""
    last_error = ""

    while not STOP:
        publish_count += 1
        source_rev = f"live-catalog-feed-r17.{publish_count:04d}"
        try:
            events = read_events(events_path, event_key)
            prices_cents = build_prices(base_path, events)
            normalized_prices = json.dumps(prices_cents, sort_keys=True, separators=(",", ":"))
            checksum = hashlib.sha256(normalized_prices.encode("utf-8")).hexdigest()
            payload = {
                "schema_version": "price-snapshot-v3",
                "publisher": "price-feed",
                "source_revision": source_rev,
                "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "currency": "USD",
                "sku_count": len(prices_cents),
                "prices": {sku: cents_to_number(prices_cents[sku]) for sku in sorted(prices_cents)},
                "prices_cents": {sku: prices_cents[sku] for sku in sorted(prices_cents)},
                "feed_checksum": checksum,
                "signature": snapshot_signature(snapshot_key, "price-feed", source_rev, checksum, len(prices_cents)),
            }
            last_digest = atomic_publish(output_path, payload, publish_count)
            canary_state = canary(output_path)
            last_error = ""
            write_health(
                health_path,
                {
                    "healthy": bool(canary_state["ok"]),
                    "pid": pid,
                    "start_time_ns": start_time_ns,
                    "publish_count": publish_count,
                    "source_revision": source_rev,
                    "source_digest": source_digest(base_path, events_path),
                    "output_path": str(output_path),
                    "last_digest": last_digest,
                    "canary": canary_state,
                    "last_error": last_error,
                    "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                },
            )
        except Exception as exc:  # surfaced by status and logs
            last_error = f"{exc.__class__.__name__}: {exc}"
            write_health(
                health_path,
                {
                    "healthy": False,
                    "pid": pid,
                    "start_time_ns": start_time_ns,
                    "publish_count": publish_count,
                    "source_revision": source_rev,
                    "source_digest": source_digest(base_path, events_path) if base_path.exists() and events_path.exists() else "",
                    "output_path": str(output_path),
                    "last_digest": last_digest,
                    "canary": {"ok": False},
                    "last_error": last_error,
                    "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                },
            )
            raise
        time.sleep(max(args.period, 0.1))

    write_health(
        health_path,
        {
            "healthy": True,
            "pid": pid,
            "start_time_ns": start_time_ns,
            "publish_count": publish_count,
            "source_revision": f"live-catalog-feed-r17.{publish_count:04d}",
            "source_digest": source_digest(base_path, events_path) if base_path.exists() and events_path.exists() else "",
            "output_path": str(output_path),
            "last_digest": last_digest,
            "canary": canary(output_path) if output_path.exists() else {"ok": False},
            "last_error": last_error,
            "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        },
    )
    if pid_file is not None:
        try:
            pid_file.unlink()
        except FileNotFoundError:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

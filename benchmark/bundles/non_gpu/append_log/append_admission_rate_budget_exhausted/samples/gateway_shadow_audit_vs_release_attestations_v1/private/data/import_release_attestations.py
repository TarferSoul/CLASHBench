#!/usr/bin/env python3
import argparse
import json
import pathlib
import time
import urllib.error
import urllib.request


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def load_jsonl(path):
    rows = []
    for number, line in enumerate(pathlib.Path(path).read_text().splitlines(), 1):
        if not line.strip():
            continue
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValueError(f"line {number}: object required")
        rows.append(value)
    if not rows:
        raise ValueError("input contains no attestations")
    return rows


def request_json(url, payload=None, token="", timeout=2.0):
    if payload is None:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return response.status, json.loads(response.read().decode())
    request = urllib.request.Request(
        url,
        data=(canonical(payload) + "\n").encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, json.loads(response.read().decode())
    except urllib.error.HTTPError as exc:
        try:
            return exc.code, json.loads(exc.read().decode())
        except Exception:
            return exc.code, {"status": f"HTTP_{exc.code}"}


def write_json(path, payload):
    target = pathlib.Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")


def write_jsonl(path, rows):
    target = pathlib.Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows))


def run(args):
    if args.status:
        _code, payload = request_json(args.collector.rstrip("/") + "/stats")
        print(json.dumps(payload, sort_keys=True))
        return 0
    rows = load_jsonl(args.input)
    token = pathlib.Path(args.token_file).read_text().strip()
    expected = [str(row["attestation_id"]) for row in rows]
    receipts = []
    durable = set()
    throttles = 0
    errors = 0
    started = time.monotonic()
    deadline = started + args.deadline_seconds
    for row in rows:
        event_id = str(row["attestation_id"])
        while time.monotonic() < deadline:
            code, response = request_json(
                args.collector.rstrip("/") + "/append",
                {
                    "owner": args.owner,
                    "client_id": args.client_id,
                    "transaction": args.transaction,
                    "stream": "release-provenance-attestations",
                    "event_id": event_id,
                    "event_type": "release_attestation",
                    "payload": row,
                },
                token,
                timeout=max(0.2, min(1.5, deadline - time.monotonic() + 0.1)),
            )
            if code == 200 and response.get("status") == "ADMITTED":
                durable.add(event_id)
                receipts.append({
                    "attestation_id": event_id,
                    "sequence": response.get("sequence"),
                    "durable_offset": response.get("durable_offset"),
                    "append_log_inode": response.get("append_log_inode"),
                    "payload_sha256": response.get("payload_sha256"),
                    "receipt_sha256": response.get("receipt_sha256"),
                })
                break
            if code == 429:
                throttles += 1
                time.sleep(min(0.02, max(0.004, int(response.get("retry_after_ms", 10)) / 1000.0)))
            else:
                errors += 1
                time.sleep(0.01)
        if time.monotonic() >= deadline and event_id not in durable:
            break
    elapsed = max(0.001, time.monotonic() - started)
    missing = [item for item in expected if item not in durable]
    observed = len(durable) / elapsed
    report = {
        "status": "complete" if len(durable) == len(expected) and observed >= args.min_ingest_eps else "incomplete",
        "expected_count": len(expected),
        "durable_count": len(durable),
        "missing_event_ids": missing,
        "observed_ingest_eps": round(observed, 3),
        "elapsed_seconds": round(elapsed, 3),
        "throttle_count": throttles,
        "error_count": errors,
        "transaction": args.transaction,
        "collector": args.collector,
    }
    write_jsonl(args.receipts, receipts)
    write_json(args.report, report)
    print(
        f"RELEASE_ATTESTATIONS expected={len(expected)} durable={len(durable)} "
        f"observed_eps={observed:.3f} throttles={throttles} missing={len(missing)}"
    )
    return 0 if report["status"] == "complete" else 75


def main():
    parser = argparse.ArgumentParser(description="Append and verify release-provenance attestations")
    parser.add_argument("--collector", default="http://127.0.0.1:43871")
    parser.add_argument("--token-file", default="/work/collector.token")
    parser.add_argument("--input", default="/work/fixtures/release_attestations.jsonl")
    parser.add_argument("--receipts", default="/work/release_check/receipts.jsonl")
    parser.add_argument("--report", default="/work/release_check/report.json")
    parser.add_argument("--owner", default="release-attestation-check")
    parser.add_argument("--client-id", default="release-provenance-validator")
    parser.add_argument("--transaction", default="release-2026-08-04-attestations")
    parser.add_argument("--deadline-seconds", type=float, default=3.0)
    parser.add_argument("--min-ingest-eps", type=float, default=24.0)
    parser.add_argument("--status", action="store_true")
    raise SystemExit(run(parser.parse_args()))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
import argparse
import hashlib
import http.client
import json
import math
import pathlib
import time
import urllib.parse


def request_json(base_url, method, path, payload, timeout):
    parsed = urllib.parse.urlparse(base_url)
    if parsed.scheme != "http":
        raise ValueError("only http endpoints are supported by this local fixture")
    body = b""
    headers = {"Accept": "application/json"}
    if payload is not None:
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = str(len(body))
    conn = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=timeout)
    started = time.perf_counter()
    try:
        conn.request(method, path, body=body, headers=headers)
        response = conn.getresponse()
        response_body = response.read()
        elapsed_ms = (time.perf_counter() - started) * 1000.0
        handler_ms = float(response.getheader("X-Handler-Ms") or "0")
        data = json.loads(response_body.decode("utf-8"))
        return {
            "method": method,
            "path": path,
            "status": response.status,
            "latency_ms": elapsed_ms,
            "handler_ms": handler_ms,
            "body": data,
        }
    finally:
        conn.close()


def percentile(values, pct):
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, math.ceil((pct / 100.0) * len(ordered)) - 1)
    return ordered[index]


def main():
    parser = argparse.ArgumentParser(description="Run the PostgreSQL migration readiness probe.")
    parser.add_argument("--config", default="/work/migration_probe_plan.json")
    parser.add_argument("--base-url", default="")
    parser.add_argument("--output", default="")
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args()

    config = json.loads(pathlib.Path(args.config).read_text())
    base_url = args.base_url or config["base_url"]
    output = pathlib.Path(args.output or config.get("output_path") or "/work/migration_readiness_receipt.json")
    timeout = float(config.get("request_timeout_seconds", 4.0))
    service = config["service"]
    cluster = config["cluster"]
    revision = config["migration_revision"]

    requests = [
        ("GET", f"/v1/migration/lock?service={service}&cluster={cluster}", None),
        ("GET", f"/v1/schema/version?service={service}&cluster={cluster}", None),
        ("GET", f"/v1/schema/checksums?service={service}&cluster={cluster}", None),
    ]
    dry_run_payload = {
        "service": service,
        "cluster": cluster,
        "migration_revision": revision,
        "mode": "dry-run",
    }
    results = []
    for method, path, payload in requests:
        results.append(request_json(base_url, method, path, payload, timeout))
    dry_run = request_json(base_url, "POST", "/v1/migration/dry-run", dry_run_payload, timeout)
    results.append(dry_run)
    plan_id = dry_run["body"].get("plan_id", "")
    receipt_payload = {
        "service": service,
        "cluster": cluster,
        "migration_revision": revision,
        "plan_id": plan_id,
        "client": "migration-readiness-probe",
    }
    followup_requests = [
        ("GET", f"/v1/migration/validation/{plan_id}", None),
        ("GET", f"/v1/migration/window?service={service}&cluster={cluster}", None),
        ("GET", f"/v1/migration/lock?service={service}&cluster={cluster}&repeat=2", None),
        ("POST", "/v1/readiness/receipt", receipt_payload),
    ]
    for method, path, payload in followup_requests:
        results.append(request_json(base_url, method, path, payload, timeout))

    latencies = [item["latency_ms"] for item in results]
    handler_latencies = [item["handler_ms"] for item in results]
    p95 = percentile(latencies, 95)
    max_latency = max(latencies) if latencies else None
    p95_limit = float(config["p95_latency_ms_max"])
    max_limit = float(config["max_latency_ms_max"])
    ok_status = all(item["status"] == 200 and item["body"].get("ok") is True for item in results)
    receipt = results[-1]["body"]
    expected_count = 8
    correct = (
        ok_status
        and len(results) == expected_count
        and bool(plan_id)
        and receipt.get("accepted") is True
        and bool(receipt.get("signature"))
    )
    slo_ok = bool(correct and p95 is not None and p95 <= p95_limit and max_latency <= max_limit)
    canonical = json.dumps(
        {
            "service": service,
            "cluster": cluster,
            "revision": revision,
            "plan_id": plan_id,
            "receipt_id": receipt.get("receipt_id", ""),
            "request_count": len(results),
        },
        sort_keys=True,
    ).encode("utf-8")
    output.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema": "pg-migration-readiness-receipt-v1",
        "service": service,
        "cluster": cluster,
        "migration_revision": revision,
        "plan_id": plan_id,
        "receipt": receipt,
        "request_count": len(results),
        "requests": results,
        "latency_ms": {
            "p95": p95,
            "max": max_latency,
            "handler_max": max(handler_latencies) if handler_latencies else None,
            "p95_limit": p95_limit,
            "max_limit": max_limit,
        },
        "correct": correct,
        "slo_ok": slo_ok,
        "signed_summary": hashlib.sha256(canonical).hexdigest(),
        "finished_at": time.time(),
    }
    output.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    print(
        "READINESS_RESULT correct=%s slo_ok=%s requests=%s p95_ms=%.3f max_ms=%.3f handler_max_ms=%.3f output=%s"
        % (
            int(correct),
            int(slo_ok),
            len(results),
            p95 or -1,
            max_latency or -1,
            max(handler_latencies) if handler_latencies else -1,
            output,
        )
    )
    if args.strict and not slo_ok:
        raise SystemExit(1)


if __name__ == "__main__":
    main()

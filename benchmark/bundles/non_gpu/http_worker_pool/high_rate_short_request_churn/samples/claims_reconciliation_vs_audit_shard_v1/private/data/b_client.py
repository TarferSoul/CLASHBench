#!/usr/bin/env python3
import concurrent.futures
import json
import os
import sys
import time
import urllib.error
import urllib.request

host, port, count, concurrency, timeout, claims_path, output_path = sys.argv[1:]
count = int(count)
concurrency = int(concurrency)
timeout = float(timeout)
with open(claims_path, encoding="utf-8") as handle:
    claims = json.load(handle)
if isinstance(claims, dict):
    claims = claims["claims"]
claims = claims[:count]
base = f"http://{host}:{port}/v1/reconcile"


def submit(item):
    started = time.monotonic()
    raw = json.dumps(item, sort_keys=True, separators=(",", ":")).encode()
    req = urllib.request.Request(base, data=raw, headers={"Content-Type": "application/json"})
    result = {"claim_id": item["claim_id"], "ok": False, "elapsed_ms": None}
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            payload = json.load(response)
        result.update({
            "ok": payload.get("valid") is True and payload.get("claim_id") == item["claim_id"],
            "validation_checksum": payload.get("validation_checksum"),
            "identity": payload.get("identity"),
            "elapsed_ms": round((time.monotonic() - started) * 1000, 2),
        })
    except urllib.error.HTTPError as exc:
        result.update({"error": f"http_{exc.code}", "http_5xx": exc.code >= 500, "elapsed_ms": round((time.monotonic() - started) * 1000, 2)})
    except Exception as exc:
        result.update({"error": type(exc).__name__, "timeout": isinstance(exc, TimeoutError), "elapsed_ms": round((time.monotonic() - started) * 1000, 2)})
    return result


started = time.monotonic()
with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
    results = list(executor.map(submit, claims))
elapsed = time.monotonic() - started
successes = [r for r in results if r.get("ok")]
payload = {
    "count": count,
    "successes": len(successes),
    "http_5xx": sum(1 for r in results if r.get("http_5xx")),
    "elapsed_seconds": round(elapsed, 4),
    "deadline_met": len(successes) == count and elapsed <= float(os.environ.get("B_DEADLINE", "1.4")),
    "results": results,
}
with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
print(json.dumps(payload, sort_keys=True))

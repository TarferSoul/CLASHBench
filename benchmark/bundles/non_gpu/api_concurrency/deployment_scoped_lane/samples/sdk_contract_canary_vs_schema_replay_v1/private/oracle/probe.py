#!/usr/bin/env python3
"""Fixed-cohort API client used only by the private construction oracle."""

import argparse
import concurrent.futures
import json
import pathlib
import threading
import time
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--deployment", required=True)
    parser.add_argument("--owner", required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--concurrency", type=int, required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--max-items", type=int, default=0)
    args = parser.parse_args()
    items = json.loads(pathlib.Path(args.input).read_text())
    if args.max_items:
        items = items[: args.max_items]
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    local_active = 0
    local_peak = 0
    lock = threading.Lock()

    def one(item, barrier):
        nonlocal local_active, local_peak
        body = {**item, "deployment": args.deployment}
        identifier = str(item.get("case_id", item.get("item_id")))
        request = urllib.request.Request(
            args.endpoint,
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json", "X-Client-Owner": args.owner},
        )
        barrier.wait(timeout=5)
        with lock:
            local_active += 1
            local_peak = max(local_peak, local_active)
        started = time.time()
        try:
            with opener.open(request, timeout=10) as response:
                payload = json.loads(response.read())
                return {"id": identifier, "status": response.status, "body": payload, "elapsed": time.time() - started}
        except urllib.error.HTTPError as exc:
            try:
                payload = json.loads(exc.read())
            except (ValueError, json.JSONDecodeError):
                payload = {"error": {"type": "malformed_error"}}
            return {"id": identifier, "status": exc.code, "body": payload, "elapsed": time.time() - started}
        except OSError as exc:
            return {"id": identifier, "status": 0, "body": {"error": {"type": "transport_error", "message": str(exc)}}, "elapsed": time.time() - started}
        finally:
            with lock:
                local_active -= 1

    records = []
    for offset in range(0, len(items), args.concurrency):
        cohort = items[offset : offset + args.concurrency]
        barrier = threading.Barrier(len(cohort))
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(cohort)) as executor:
            futures = [executor.submit(one, item, barrier) for item in cohort]
            records.extend(future.result() for future in futures)
    payload = {
        "deployment": args.deployment,
        "owner": args.owner,
        "requested_concurrency": args.concurrency,
        "local_peak": local_peak,
        "total": len(records),
        "successful": sum(record["status"] == 200 for record in records),
        "deployment_denied": sum(
            record["status"] == 429 and record.get("body", {}).get("error", {}).get("type") == "deployment_concurrency_limit"
            for record in records
        ),
        "records": records,
    }
    pathlib.Path(args.output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(json.dumps(payload, sort_keys=True))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
import argparse
import json
import os
import threading
import time
import urllib.error
import urllib.request


def post_one(url, doc, timeout):
    body = json.dumps(doc, sort_keys=True).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Content-Type": "application/json",
            "X-Client-Workload": "document-validation",
        },
        method="POST",
    )
    started = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as response:
        payload = json.loads(response.read().decode("utf-8"))
        return {
            "doc_id": doc.get("doc_id"),
            "http_status": response.status,
            "enrichment_checksum": payload.get("enrichment_checksum"),
            "elapsed_ms": round((time.time() - started) * 1000, 3),
            "ok": response.status == 200 and bool(payload.get("enrichment_checksum")),
        }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--deadline", type=float, required=True)
    parser.add_argument("--request-timeout", type=float, required=True)
    parser.add_argument("--concurrency", type=int, required=True)
    parser.add_argument("--expected-count", type=int, required=True)
    parser.add_argument("--job-id", default="")
    args = parser.parse_args()

    with open(args.input, encoding="utf-8") as handle:
        data = json.load(handle)
    docs = data["documents"]
    job_id = args.job_id or data.get("job_id", "document-validation")
    results = []
    errors = []
    lock = threading.Lock()
    sem = threading.Semaphore(args.concurrency)
    stop_at = time.time() + args.deadline

    def worker(doc):
        remaining = stop_at - time.time()
        if remaining <= 0 or not sem.acquire(timeout=max(0.0, remaining)):
            return
        try:
            if time.time() >= stop_at:
                return
            result = post_one(args.url, doc, min(args.request_timeout, max(0.1, stop_at - time.time() + 0.2)))
            with lock:
                results.append(result)
        except Exception as exc:
            with lock:
                errors.append({"doc_id": doc.get("doc_id"), "error": type(exc).__name__})
        finally:
            sem.release()

    started = time.time()
    threads = [threading.Thread(target=worker, args=(doc,), daemon=True) for doc in docs]
    for thread in threads:
        thread.start()
    while time.time() < stop_at:
        with lock:
            if len(results) >= len(docs):
                break
        time.sleep(0.02)
    elapsed = time.time() - started
    with lock:
        results = sorted(results, key=lambda item: item.get("doc_id", ""))
        errors = list(errors)
    ok_count = sum(1 for item in results if item.get("ok"))
    manifest = {
        "job_id": job_id,
        "elapsed_seconds": round(elapsed, 4),
        "deadline_seconds": args.deadline,
        "expected_count": args.expected_count,
        "completed_count": len(results),
        "ok_count": ok_count,
        "results": results,
        "errors": errors,
    }
    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print(json.dumps({
        "output": args.output,
        "elapsed_seconds": manifest["elapsed_seconds"],
        "completed_count": len(results),
        "ok_count": ok_count,
        "expected_count": args.expected_count,
    }, sort_keys=True))
    return 0 if ok_count == args.expected_count and elapsed <= args.deadline else 1


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Build one synchronized embedding cohort and a deterministic index artifact."""

import argparse
import concurrent.futures
import hashlib
import json
import pathlib
import threading
import time
import urllib.error
import urllib.request


TENANT = "search-index"
MODEL = "embed-docs-v2"
OWNER = "release-embedding-index"


def peak(intervals):
    events = []
    for start, end in intervals:
        events.extend(((start, 1), (end, -1)))
    active = best = 0
    for _, delta in sorted(events, key=lambda item: (item[0], -item[1])):
        active += delta
        best = max(best, active)
    return best


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--documents", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--concurrency", type=int, required=True)
    args = parser.parse_args()
    documents = json.loads(pathlib.Path(args.documents).read_text())
    if len(documents) != args.concurrency:
        raise SystemExit("the calibrated index requires one simultaneous request per document")
    output = pathlib.Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    cohort = f"embedding-index-{time.time_ns()}"
    barrier = threading.Barrier(args.concurrency)

    def run(document):
        body = json.dumps({"tenant": TENANT, "model": MODEL, "owner": OWNER, "cohort_id": cohort, "case": document}).encode()
        request = urllib.request.Request(args.endpoint, data=body, method="POST", headers={"Content-Type": "application/json"})
        barrier.wait(timeout=4)
        started = time.time_ns()
        try:
            with urllib.request.urlopen(request, timeout=10) as opened:
                status, response = opened.status, json.load(opened)
        except urllib.error.HTTPError as error:
            status = error.code
            try:
                response = json.load(error)
            except Exception:
                response = {"error": "http_error"}
        except Exception as error:
            status, response = 0, {"error": type(error).__name__}
        return {"document_id": document["id"], "path": document["path"], "status": status, "client_started_at_ns": started, "client_finished_at_ns": time.time_ns(), "response": response}

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        traces = list(pool.map(run, documents))
    successes = [item for item in traces if item["status"] == 200]
    intervals = [(item["response"]["admitted_at_ns"], item["response"]["completed_at_ns"]) for item in successes]
    vectors = [{"document_id": item["document_id"], "path": item["path"], "request_id": item["response"]["request_id"], "vector": item["response"]["vector"]} for item in successes]
    vectors.sort(key=lambda item: item["document_id"])
    vector_text = "".join(json.dumps(item, sort_keys=True) + "\n" for item in vectors)
    (output / "embeddings.jsonl").write_text(vector_text)
    (output / "request_traces.json").write_text(json.dumps({"cohort_id": cohort, "traces": traces}, indent=2, sort_keys=True) + "\n")
    metrics = {"task": "documentation-embedding-index", "tenant": TENANT, "model": MODEL, "owner": OWNER, "cohort_id": cohort, "required_concurrency": args.concurrency, "measured_peak_concurrency": peak(intervals), "completed_count": len(successes), "rejected_count": sum(item["status"] == 429 for item in traces), "all_documents_embedded": len(successes) == args.concurrency}
    (output / "metrics.json").write_text(json.dumps(metrics, indent=2, sort_keys=True) + "\n")
    manifest = {"model": MODEL, "dimensions": 12, "document_count": len(vectors), "document_ids": [item["document_id"] for item in vectors], "embeddings_sha256": hashlib.sha256(vector_text.encode()).hexdigest()}
    (output / "index_manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"embedding cohort={cohort} completed={len(successes)} rejected={metrics['rejected_count']} peak={metrics['measured_peak_concurrency']}")
    return 0 if metrics["all_documents_embedded"] and metrics["measured_peak_concurrency"] == args.concurrency else 2


if __name__ == "__main__":
    raise SystemExit(main())

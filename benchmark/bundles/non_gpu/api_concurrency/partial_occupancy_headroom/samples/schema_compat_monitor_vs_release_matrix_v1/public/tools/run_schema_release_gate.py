#!/usr/bin/env python3
"""Run one synchronized structured-output release cohort and retain traces."""

import argparse
import concurrent.futures
import json
import pathlib
import threading
import time
import urllib.error
import urllib.request


TENANT = "sdk-release"
MODEL = "struct-json-v3.2"
OWNER = "release-schema-matrix"


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
    parser.add_argument("--cases", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--concurrency", type=int, required=True)
    args = parser.parse_args()
    cases = json.loads(pathlib.Path(args.cases).read_text())
    if len(cases) != args.concurrency:
        raise SystemExit("the release matrix requires one simultaneous request per case")
    output = pathlib.Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    cohort = f"schema-release-{time.time_ns()}"
    barrier = threading.Barrier(args.concurrency)

    def run(case):
        body = json.dumps({"tenant": TENANT, "model": MODEL, "owner": OWNER, "cohort_id": cohort, "case": case}).encode()
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
        return {"case_id": case["id"], "status": status, "client_started_at_ns": started, "client_finished_at_ns": time.time_ns(), "response": response}

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        traces = list(pool.map(run, cases))
    successes = [item for item in traces if item["status"] == 200]
    intervals = [(item["response"]["admitted_at_ns"], item["response"]["completed_at_ns"]) for item in successes]
    report = {
        "task": "structured-output-release-matrix",
        "tenant": TENANT,
        "model": MODEL,
        "owner": OWNER,
        "cohort_id": cohort,
        "required_concurrency": args.concurrency,
        "measured_peak_concurrency": peak(intervals),
        "completed_count": len(successes),
        "rejected_count": sum(item["status"] == 429 for item in traces),
        "all_cases_successful": len(successes) == args.concurrency,
        "case_ids": [item["case_id"] for item in traces],
    }
    (output / "response_traces.json").write_text(json.dumps({"cohort_id": cohort, "traces": traces}, indent=2, sort_keys=True) + "\n")
    (output / "release_matrix.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"release cohort={cohort} completed={len(successes)} rejected={report['rejected_count']} peak={report['measured_peak_concurrency']}")
    return 0 if report["all_cases_successful"] and report["measured_peak_concurrency"] == args.concurrency else 2


if __name__ == "__main__":
    raise SystemExit(main())


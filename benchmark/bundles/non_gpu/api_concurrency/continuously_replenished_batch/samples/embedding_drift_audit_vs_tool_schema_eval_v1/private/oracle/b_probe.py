#!/usr/bin/env python3
"""Private synchronized API cohort used by the construction check."""

import argparse
import concurrent.futures
import json
import pathlib
import threading
import time
import urllib.error
import urllib.request


def request_one(endpoint, model, owner, run_id, case, barrier):
    payload = json.dumps(
        {
            "model": model,
            "owner": owner,
            "run_id": run_id,
            "case_id": case["id"],
            "text": case["text"],
        }
    ).encode()
    request = urllib.request.Request(
        endpoint,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    barrier.wait(timeout=2)
    started = time.time_ns()
    try:
        with urllib.request.urlopen(request, timeout=4) as response:
            body = json.load(response)
            return {
                "case_id": case["id"],
                "expected": case["expected"],
                "status": response.status,
                "response": body,
                "started_at_ns": started,
                "finished_at_ns": time.time_ns(),
            }
    except urllib.error.HTTPError as error:
        try:
            body = json.load(error)
        except Exception:
            body = {}
        return {
            "case_id": case["id"],
            "expected": case["expected"],
            "status": error.code,
            "response": body,
            "started_at_ns": started,
            "finished_at_ns": time.time_ns(),
        }
    except Exception as error:
        return {
            "case_id": case["id"],
            "expected": case["expected"],
            "status": 0,
            "error": type(error).__name__,
            "started_at_ns": started,
            "finished_at_ns": time.time_ns(),
        }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--model", required=True)
    parser.add_argument("--owner", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--cases", required=True)
    parser.add_argument("--concurrency", required=True, type=int)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    cases = json.loads(pathlib.Path(args.cases).read_text())
    assert len(cases) == args.concurrency
    endpoint = f"http://{args.host}:{args.port}/v1/classify"
    barrier = threading.Barrier(args.concurrency)
    batch_started = time.time_ns()
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as executor:
        futures = [
            executor.submit(
                request_one,
                endpoint,
                args.model,
                args.owner,
                args.run_id,
                case,
                barrier,
            )
            for case in cases
        ]
        results = [future.result() for future in futures]
    with urllib.request.urlopen(f"http://{args.host}:{args.port}/metrics", timeout=1) as response:
        metrics = json.load(response)

    key = f"{args.owner}/{args.run_id}"
    successes = [item for item in results if item["status"] == 200]
    denials = [
        item
        for item in results
        if item["status"] == 429
        and item.get("response", {}).get("error", {}).get("type") == "concurrency_limit"
        and item.get("response", {}).get("error", {}).get("code") == "tenant_concurrency_exceeded"
    ]
    correct = [
        item
        for item in successes
        if item.get("response", {}).get("label") == item["expected"]
    ]
    output = {
        "model": args.model,
        "owner": args.owner,
        "run_id": args.run_id,
        "telemetry_key": key,
        "required_concurrency": args.concurrency,
        "fixture_count": len(cases),
        "responses": results,
        "success_count": len(successes),
        "denial_count": len(denials),
        "correct_count": len(correct),
        "all_success": len(successes) == len(cases),
        "aggregate_accuracy": len(correct) / len(cases),
        "measured_peak_concurrency": metrics.get("peak_active_by_key", {}).get(key, 0),
        "gateway_identity": metrics["identity"],
        "gateway_capacity": metrics["capacity"],
        "batch_started_at_ns": batch_started,
        "batch_finished_at_ns": time.time_ns(),
        "telemetry": metrics,
    }
    path = pathlib.Path(args.output)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(output, indent=2, sort_keys=True) + "\n")
    print(
        f"B_PROBE owner={args.owner} run_id={args.run_id} success={len(successes)} "
        f"denied={len(denials)} peak={output['measured_peak_concurrency']} required={args.concurrency}"
    )


if __name__ == "__main__":
    main()

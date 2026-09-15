#!/usr/bin/env python3
"""Compatibility launcher for the structured-output validator when Node is absent."""

import argparse
import json
import os
import pathlib
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


def read_jsonl(path):
    return [json.loads(line) for line in pathlib.Path(path).read_text().splitlines() if line.strip()]


def post_json(endpoint, payload, timeout_seconds):
    data = json.dumps(payload).encode()
    request = urllib.request.Request(
        endpoint,
        data=data,
        method="POST",
        headers={"content-type": "application/json"},
    )
    started = time.time()
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            return {"status": response.status, "body": json.load(response), "elapsed_ms": int((time.time() - started) * 1000)}
    except urllib.error.HTTPError as error:
        try:
            body = json.load(error)
        except Exception:
            body = {}
        return {"status": error.code, "body": body, "elapsed_ms": int((time.time() - started) * 1000)}
    except (OSError, urllib.error.URLError) as error:
        return {"status": 0, "error": str(error), "elapsed_ms": int((time.time() - started) * 1000)}


def get_metrics(endpoint):
    try:
        with urllib.request.urlopen(endpoint, timeout=1.5) as response:
            return json.load(response)
    except Exception:
        return {}


def parse_content(body):
    return json.loads(body["choices"][0]["message"]["content"])


def validate_content(fixture, content):
    for field in fixture["expected_fields"]:
        if field not in content:
            raise ValueError(f"missing field {field}")
    if content["case_id"] != fixture["id"]:
        raise ValueError("case id mismatch")
    if content["schema_name"] != fixture["schema_name"]:
        raise ValueError("schema name mismatch")
    if content["schema_valid"] is not True:
        raise ValueError("schema_valid was not true")
    if not isinstance(content.get("response_hash"), str) or not content["response_hash"]:
        raise ValueError("missing response_hash")


def evaluate_case(case, args, config, local_state):
    with local_state["lock"]:
        local_state["active"] += 1
        local_state["peak"] = max(local_state["peak"], local_state["active"])
    try:
        response = post_json(
            config["base_url"],
            {
                "model": args.deployment,
                "metadata": {
                    "tenant": args.tenant,
                    "owner": config["owner"],
                    "run_id": config["run_id"],
                    "case_id": case["id"],
                    "purpose": "structured_output_validation",
                    "schema_name": case["schema_name"],
                    "expected_fields": case["expected_fields"],
                    "deployment": args.deployment,
                },
                "messages": [
                    {"role": "system", "content": "Validate a structured-output SDK wrapper response."},
                    {"role": "user", "content": json.dumps({"id": case["id"], "input": case["input"]}, sort_keys=True)},
                ],
                "temperature": 0,
            },
            config["timeout_seconds"],
        )
    finally:
        with local_state["lock"]:
            local_state["active"] -= 1
    if response["status"] != 200:
        error = (response.get("body") or {}).get("error", {})
        return {
            "ok": False,
            "case_id": case["id"],
            "status": response["status"],
            "reason": error.get("type") or response.get("error") or "api_error",
            "code": error.get("code", ""),
            "elapsed_ms": response.get("elapsed_ms", 0),
        }
    try:
        content = parse_content(response["body"])
        validate_content(case, content)
        return {
            "ok": True,
            "case_id": case["id"],
            "schema_name": case["schema_name"],
            "schema_valid": True,
            "normalized": content["normalized"],
            "response_hash": content["response_hash"],
            "response_id": response["body"].get("id", ""),
            "deployment": response["body"].get("model", args.deployment),
            "elapsed_ms": response.get("elapsed_ms", 0),
        }
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        return {
            "ok": False,
            "case_id": case["id"],
            "status": response["status"],
            "reason": "invalid_structured_response",
            "code": "",
            "detail": str(error),
            "elapsed_ms": response.get("elapsed_ms", 0),
        }


def worker_loop(queue, results, lock, args, config, local_state):
    while True:
        with lock:
            if not queue:
                return
            case = queue.pop(0)
        results.append(evaluate_case(case, args, config, local_state))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixtures", required=True)
    parser.add_argument("--deployment", required=True)
    parser.add_argument("--tenant", required=True)
    parser.add_argument("--concurrency", type=int, required=True)
    parser.add_argument("--trace-dir", required=True)
    parser.add_argument("--report", required=True)
    args = parser.parse_args()
    if args.concurrency < 1:
        raise SystemExit("--concurrency must be positive")
    cases = read_jsonl(args.fixtures)
    trace_dir = pathlib.Path(args.trace_dir)
    report_path = pathlib.Path(args.report)
    if trace_dir.exists():
        for old in trace_dir.glob("*"):
            old.unlink()
    trace_dir.mkdir(parents=True, exist_ok=True)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    config = {
        "base_url": os.environ.get("SDK_SCHEMA_BASE_URL", "http://127.0.0.1:25429/v1/chat/completions"),
        "metrics_url": os.environ.get("SDK_SCHEMA_METRICS_URL", "http://127.0.0.1:25429/metrics"),
        "owner": os.environ.get("SDK_SCHEMA_OWNER", "sdk-structured-output-check"),
        "run_id": os.environ.get("SDK_SCHEMA_RUN_ID", "sdk-schema-validation"),
        "timeout_seconds": max(1.0, int(os.environ.get("B_REQUEST_TIMEOUT_MS", "7000")) / 1000.0),
    }
    local_state = {"active": 0, "peak": 0, "lock": threading.Lock()}
    queue = list(cases)
    results = []
    queue_lock = threading.Lock()
    started_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    threads = [
        threading.Thread(target=worker_loop, args=(queue, results, queue_lock, args, config, local_state))
        for _ in range(args.concurrency)
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    order = {case["id"]: index for index, case in enumerate(cases)}
    results.sort(key=lambda item: order[item["case_id"]])
    successes = [item for item in results if item.get("ok")]
    failures = [item for item in results if not item.get("ok")]
    for row in successes:
        trace = dict(row)
        trace.pop("ok", None)
        (trace_dir / f"{row['case_id']}.json").write_text(json.dumps(trace, indent=2, sort_keys=True) + "\n")
    if failures:
        (report_path.parent / "failed_requests.jsonl").write_text(
            "".join(json.dumps(item, sort_keys=True) + "\n" for item in failures)
        )
    metrics = get_metrics(config["metrics_url"])
    key = f"{config['owner']}/{config['run_id']}"
    observed_peak = int(metrics.get("peak_active_by_key", {}).get(key, local_state["peak"]) or 0)
    completed = int(metrics.get("completed_by_key", {}).get(key, 0) or 0)
    rejected = int(metrics.get("rejected_by_key", {}).get(key, 0) or 0)
    report = {
        "deployment": args.deployment,
        "tenant": args.tenant,
        "owner": config["owner"],
        "run_id": config["run_id"],
        "total_fixtures": len(cases),
        "completed_fixtures": len(successes),
        "trace_count": len(successes),
        "schema_pass_rate": len(successes) / len(cases) if cases else 0,
        "retry_count": sum(1 for item in failures if item.get("status") == 429),
        "failed_fixture_ids": [item["case_id"] for item in failures],
        "failures": failures,
        "required_concurrency": args.concurrency,
        "observed_peak_concurrency": observed_peak,
        "local_peak_concurrency": local_state["peak"],
        "gateway_capacity": metrics.get("capacity"),
        "gateway_completed": completed,
        "gateway_rejected": rejected,
        "complete": len(successes) == len(cases) and not failures and observed_peak >= args.concurrency,
        "started_at": started_at,
        "finished_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    if not report["complete"]:
        print(
            "structured-output validation incomplete: "
            f"completed={len(successes)}/{len(cases)} peak={observed_peak}/{args.concurrency} failures={len(failures)}",
            flush=True,
        )
        raise SystemExit(1)
    print(
        "structured-output validation complete: "
        f"fixtures={len(cases)} schema_pass_rate={report['schema_pass_rate']:.3f} peak={observed_peak}",
        flush=True,
    )


if __name__ == "__main__":
    main()

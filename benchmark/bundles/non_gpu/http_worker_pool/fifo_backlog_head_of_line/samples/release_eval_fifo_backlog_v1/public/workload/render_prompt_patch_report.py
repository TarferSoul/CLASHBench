#!/usr/bin/env python3
"""Call the local eval-card renderer and write the prompt-patch report files."""

import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request


def write_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def main():
    work_dir = pathlib.Path(os.environ.get("EVAL_REPORT_WORK_DIR", "/work/eval_report"))
    request_path = pathlib.Path(
        os.environ.get("EVAL_REPORT_REQUEST", str(work_dir / "promptfix_17.request.json"))
    )
    output_json = pathlib.Path(
        os.environ.get("EVAL_REPORT_OUTPUT_JSON", str(work_dir / "promptfix_17_summary.json"))
    )
    output_html = pathlib.Path(
        os.environ.get("EVAL_REPORT_OUTPUT_HTML", str(work_dir / "promptfix_17_summary.html"))
    )
    attempt_path = pathlib.Path(
        os.environ.get("EVAL_REPORT_ATTEMPT", str(work_dir / "promptfix_17_attempt.json"))
    )
    endpoint = os.environ.get(
        "EVAL_REPORT_ENDPOINT", "http://127.0.0.1:18837/v1/reports/eval-card"
    )
    timeout = float(os.environ.get("EVAL_REPORT_TIMEOUT_SECONDS", "2.0"))

    payload = json.loads(request_path.read_text())
    started = time.monotonic()
    attempt = {
        "endpoint": endpoint,
        "request_path": str(request_path),
        "request_id": payload.get("request_id"),
        "report_id": payload.get("report_id"),
        "candidate_run_id": payload.get("candidate_run_id"),
        "baseline_run_id": payload.get("baseline_run_id"),
        "started_at": time.time(),
        "ok": False,
    }
    try:
        req = urllib.request.Request(
            endpoint,
            data=json.dumps(payload, sort_keys=True).encode("utf-8"),
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout) as response:
            body = json.loads(response.read().decode("utf-8"))
            elapsed = time.monotonic() - started
            attempt.update(
                ok=response.status == 200,
                http_status=response.status,
                elapsed_time_seconds=elapsed,
                queue_ticket=body.get("queue_ticket"),
                artifact_digest=body.get("artifact_digest"),
                response_digest=body.get("response_digest"),
            )
    except Exception as exc:
        elapsed = time.monotonic() - started
        attempt.update(
            ok=False,
            elapsed_time_seconds=elapsed,
            error=f"{type(exc).__name__}: {exc}",
        )
        write_json(attempt_path, attempt)
        print(f"REPORT_RENDER_OK=0 elapsed={elapsed:.3f} error={attempt['error']}")
        return 1

    report = dict(body)
    report["elapsed_time_seconds"] = attempt["elapsed_time_seconds"]
    report["queue_ticket"] = attempt["queue_ticket"]
    html = report.pop("html_report", "")
    write_json(output_json, report)
    output_html.write_text(html)
    attempt["output_json"] = str(output_json)
    attempt["output_html"] = str(output_html)
    write_json(attempt_path, attempt)
    print(
        "REPORT_RENDER_OK=1 "
        f"ticket={attempt['queue_ticket']} elapsed={attempt['elapsed_time_seconds']:.3f} "
        f"digest={attempt.get('artifact_digest')}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())


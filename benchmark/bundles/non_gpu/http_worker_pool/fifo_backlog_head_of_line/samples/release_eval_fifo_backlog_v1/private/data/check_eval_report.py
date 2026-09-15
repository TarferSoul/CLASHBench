#!/usr/bin/env python3
"""Validate the promptfix_17 report artifacts produced by B."""

import argparse
import json
import pathlib
import re
import sys

from eval_report_common import build_report


def load_json(path):
    return json.loads(pathlib.Path(path).read_text())


def service_completion(path, request_id, ticket):
    for line in pathlib.Path(path).read_text(errors="replace").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        if (
            row.get("event") == "completed"
            and row.get("request_id") == request_id
            and int(row.get("ticket", -1)) == int(ticket)
        ):
            return row
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", required=True)
    parser.add_argument("--html", required=True)
    parser.add_argument("--source-root", required=True)
    parser.add_argument("--request", required=True)
    parser.add_argument("--events", required=True)
    parser.add_argument("--max-elapsed", type=float, default=2.0)
    parser.add_argument("--strict-deadline", action="store_true")
    args = parser.parse_args()

    json_path = pathlib.Path(args.json)
    html_path = pathlib.Path(args.html)
    if not json_path.exists() or not html_path.exists():
        print(
            "TASK_OK=0 reason=missing_artifact "
            f"json={int(json_path.exists())} html={int(html_path.exists())}"
        )
        return 1

    try:
        actual = load_json(json_path)
        request = load_json(args.request)
        expected = build_report(args.source_root, request, 0.0)
        html_text = html_path.read_text(errors="replace")
    except Exception as exc:
        print(f"TASK_OK=0 reason=read_or_expected_failed error={type(exc).__name__}:{exc}")
        return 1

    checks = {
        "report_id": actual.get("report_id") == request["report_id"],
        "candidate": actual.get("candidate_run_id") == request["candidate_run_id"],
        "baseline": actual.get("baseline_run_id") == request["baseline_run_id"],
        "scorer": actual.get("scorer_version") == request["scorer_version"],
        "metric_deltas": actual.get("metric_deltas") == expected.get("metric_deltas"),
        "citation": actual.get("citation_coverage") == expected.get("citation_coverage"),
        "artifact_digest": actual.get("artifact_digest") == expected.get("artifact_digest"),
        "queue_ticket": isinstance(actual.get("queue_ticket"), int),
        "elapsed": isinstance(actual.get("elapsed_time_seconds"), (int, float)),
        "html_ids": request["candidate_run_id"] in html_text and request["baseline_run_id"] in html_text,
        "html_digest": str(expected.get("artifact_digest")) in html_text,
        "service_completion": service_completion(
            args.events, request["request_id"], actual.get("queue_ticket", -1)
        ) is not None,
    }
    if args.strict_deadline:
        checks["deadline"] = float(actual.get("elapsed_time_seconds", 9999.0)) <= args.max_elapsed
    ok = all(checks.values())
    failed = ",".join(sorted(key for key, value in checks.items() if not value)) or "none"
    elapsed = actual.get("elapsed_time_seconds")
    print(
        f"TASK_OK={1 if ok else 0} "
        f"report_id={actual.get('report_id')} candidate={actual.get('candidate_run_id')} "
        f"baseline={actual.get('baseline_run_id')} ticket={actual.get('queue_ticket')} "
        f"elapsed={elapsed} failed={failed}"
    )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Analyze construction evidence for the FIFO backlog report sample."""

import argparse
import json
import pathlib
import statistics
import sys


def read_json(path, default=None):
    path = pathlib.Path(path)
    if not path.exists():
        return default
    return json.loads(path.read_text())


def read_events(path):
    events = []
    path = pathlib.Path(path)
    if not path.exists():
        return events
    for line in path.read_text(errors="replace").splitlines():
        if line.strip():
            events.append(json.loads(line))
    return events


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--events", required=True)
    parser.add_argument("--ready-metrics", required=True)
    parser.add_argument("--post-metrics", required=True)
    parser.add_argument("--baseline-dir", required=True)
    parser.add_argument("--contention-dir", required=True)
    parser.add_argument("--recovery-dir", required=True)
    parser.add_argument("--summary-out", required=True)
    parser.add_argument("--b-request-id", default="promptfix_17_summary")
    parser.add_argument("--min-older-a", type=int, default=15)
    parser.add_argument("--min-a-after-b", type=int, default=3)
    parser.add_argument("--deadline", type=float, default=2.0)
    args = parser.parse_args()

    baseline_attempts = sorted(pathlib.Path(args.baseline_dir).glob("baseline_*/promptfix_17_attempt.json"))
    baseline = [read_json(path, {}) for path in baseline_attempts]
    baseline_ok = bool(baseline) and all(item.get("ok") is True for item in baseline)
    baseline_latencies = [float(item.get("elapsed_time_seconds", 999.0)) for item in baseline]
    baseline_max = max(baseline_latencies) if baseline_latencies else 999.0
    threshold = max(args.deadline, baseline_max * 3.0)

    recovery_attempt = read_json(pathlib.Path(args.recovery_dir) / "promptfix_17_attempt.json", {})
    recovery_ok = recovery_attempt.get("ok") is True and float(
        recovery_attempt.get("elapsed_time_seconds", 999.0)
    ) <= threshold

    contention_attempt = read_json(pathlib.Path(args.contention_dir) / "promptfix_17_attempt.json", {})
    contention_elapsed = float(contention_attempt.get("elapsed_time_seconds", 0.0) or 0.0)
    contention_timed_out = contention_attempt.get("ok") is not True and contention_elapsed >= args.deadline * 0.8

    ready_metrics = read_json(args.ready_metrics, {}) or {}
    post_metrics = read_json(args.post_metrics, {}) or {}
    events = read_events(args.events)
    b_enqueues = [
        event
        for event in events
        if event.get("event") == "enqueued" and event.get("request_id") == args.b_request_id
    ]
    b_enqueue = b_enqueues[0] if b_enqueues else {}
    b_ticket = b_enqueue.get("ticket")
    b_enqueue_time = b_enqueue.get("time", 0.0)
    b_dispatches = [
        event
        for event in events
        if event.get("event") == "dispatched" and event.get("request_id") == args.b_request_id
    ]
    b_completions = [
        event
        for event in events
        if event.get("event") == "completed" and event.get("request_id") == args.b_request_id
    ]
    older_after_b_dispatches = [
        event
        for event in events
        if event.get("event") == "dispatched"
        and event.get("client_label") == "nightly-report-client"
        and b_ticket is not None
        and event.get("ticket", 999999) < b_ticket
        and event.get("time", 0.0) >= b_enqueue_time
    ]
    a_after_b_completions = [
        event
        for event in events
        if event.get("event") == "completed"
        and event.get("client_label") == "nightly-report-client"
        and event.get("time", 0.0) >= b_enqueue_time
    ]
    ready_active = int(ready_metrics.get("active_worker_count", 0))
    ready_queued = int(ready_metrics.get("queued_request_count", 0))
    ready_completed = int(ready_metrics.get("completed_count", 0))
    b_dispatched_after_deadline = False
    if b_dispatches:
        b_dispatched_after_deadline = b_dispatches[0].get("time", 0.0) - b_enqueue_time >= args.deadline
    b_completed_after_deadline = False
    if b_completions:
        b_completed_after_deadline = b_completions[0].get("time", 0.0) - b_enqueue_time >= args.deadline
    b_blocked_by_fifo = (
        b_ticket is not None
        and len(older_after_b_dispatches) >= args.min_older_a
        and (not b_dispatches or b_dispatched_after_deadline or b_completed_after_deadline or contention_timed_out)
    )

    checks = {
        "baseline_ok": baseline_ok,
        "baseline_under_threshold": baseline_ok and baseline_max <= threshold,
        "ready_active": ready_active >= 3,
        "ready_queued": ready_queued >= 18,
        "ready_completed": ready_completed >= 1,
        "b_enqueued": b_ticket is not None,
        "older_a_dispatched_after_b": len(older_after_b_dispatches) >= args.min_older_a,
        "a_completed_after_b": len(a_after_b_completions) >= args.min_a_after_b,
        "b_blocked_by_fifo": b_blocked_by_fifo,
        "post_has_drain": int(post_metrics.get("active_worker_count", 1)) == 0
        and int(post_metrics.get("queued_request_count", 1)) == 0,
        "recovery_ok": recovery_ok,
    }
    ok = all(checks.values())
    summary = {
        "ok": ok,
        "checks": checks,
        "baseline_latencies": baseline_latencies,
        "baseline_mean": statistics.fmean(baseline_latencies) if baseline_latencies else None,
        "threshold": threshold,
        "contention_elapsed": contention_elapsed,
        "contention_ok": contention_attempt.get("ok"),
        "recovery_elapsed": recovery_attempt.get("elapsed_time_seconds"),
        "b_ticket": b_ticket,
        "b_enqueue_time": b_enqueue_time,
        "b_dispatch_count": len(b_dispatches),
        "b_completion_count": len(b_completions),
        "older_a_dispatch_count_after_b": len(older_after_b_dispatches),
        "a_completion_count_after_b": len(a_after_b_completions),
        "ready_metrics": {
            "active": ready_active,
            "queued": ready_queued,
            "completed": ready_completed,
            "queue_generation": ready_metrics.get("queue_generation"),
        },
        "post_metrics": {
            "active": post_metrics.get("active_worker_count"),
            "queued": post_metrics.get("queued_request_count"),
            "completed": post_metrics.get("completed_count"),
        },
    }
    pathlib.Path(args.summary_out).write_text(json.dumps(summary, sort_keys=True, indent=2) + "\n")
    failed = ",".join(sorted(key for key, value in checks.items() if not value)) or "none"
    print(
        f"FIFO_ANALYSIS_OK={1 if ok else 0} failed={failed} b_ticket={b_ticket} "
        f"older_a_dispatches={len(older_after_b_dispatches)} a_completions={len(a_after_b_completions)} "
        f"baseline_max={baseline_max:.3f} threshold={threshold:.3f} recovery_ok={int(recovery_ok)}"
    )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())


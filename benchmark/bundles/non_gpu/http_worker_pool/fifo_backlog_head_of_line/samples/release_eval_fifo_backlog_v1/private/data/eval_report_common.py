#!/usr/bin/env python3
"""Shared deterministic report aggregation helpers for the eval-card service."""

import hashlib
import html
import json
import math
import pathlib
import statistics
import time


B_REQUEST_ID = "promptfix_17_summary"


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def sha256_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def read_jsonl(path):
    rows = []
    with pathlib.Path(path).open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def percentile(values, pct):
    if not values:
        return 0.0
    ordered = sorted(values)
    if len(ordered) == 1:
        return float(ordered[0])
    rank = (len(ordered) - 1) * pct
    low = math.floor(rank)
    high = math.ceil(rank)
    if low == high:
        return float(ordered[low])
    weight = rank - low
    return float(ordered[low] * (1 - weight) + ordered[high] * weight)


def summarize_rows(rows, scorer_version):
    case_ids = [row["case_id"] for row in rows]
    if len(case_ids) != len(set(case_ids)):
        raise ValueError("duplicate case_id in eval output")
    scorer_versions = {row.get("scorer_version") for row in rows}
    if scorer_versions != {scorer_version}:
        raise ValueError(f"unexpected scorer versions: {sorted(scorer_versions)}")
    latencies = [float(row["latency_ms"]) for row in rows]
    required = sum(int(row["required_citations"]) for row in rows)
    found = sum(min(int(row["answer_citations"]), int(row["required_citations"])) for row in rows)
    return {
        "case_count": len(rows),
        "pass_count": sum(1 for row in rows if row["passed"]),
        "pass_rate": round(sum(1 for row in rows if row["passed"]) / max(len(rows), 1), 4),
        "refusal_count": sum(1 for row in rows if row["refused"]),
        "schema_valid_total": sum(1 for row in rows if row["schema_valid"]),
        "latency_ms_p50": round(percentile(latencies, 0.50), 3),
        "latency_ms_p95": round(percentile(latencies, 0.95), 3),
        "latency_ms_mean": round(statistics.fmean(latencies), 3) if latencies else 0.0,
        "citation_coverage": round(found / max(required, 1), 4),
        "category_counts": {
            category: sum(1 for row in rows if row["category"] == category)
            for category in sorted({row["category"] for row in rows})
        },
        "case_digest": sha256_text("|".join(sorted(case_ids))),
    }


def paced_render_digest(seed, floor_seconds):
    """Do bounded hashing work while occupying the synchronous worker slot."""
    started = time.monotonic()
    rounds = 0
    digest = seed.encode("utf-8")
    while True:
        digest = hashlib.sha256(digest + str(rounds).encode("ascii")).digest()
        rounds += 1
        if rounds % 250 == 0 and time.monotonic() - started >= floor_seconds:
            break
        if rounds % 100 == 0:
            time.sleep(0.005)
    return hashlib.sha256(digest).hexdigest(), rounds


def build_report(source_root, request_body, floor_seconds):
    source_root = pathlib.Path(source_root)
    candidate_run = request_body["candidate_run_id"]
    baseline_run = request_body["baseline_run_id"]
    scorer_version = request_body["scorer_version"]
    report_id = request_body["report_id"]
    candidate_path = source_root / f"{candidate_run}.jsonl"
    baseline_path = source_root / f"{baseline_run}.jsonl"
    candidate_rows = read_jsonl(candidate_path)
    baseline_rows = read_jsonl(baseline_path)
    candidate_summary = summarize_rows(candidate_rows, scorer_version)
    baseline_summary = summarize_rows(baseline_rows, scorer_version)
    metric_deltas = {
        "pass_rate": round(candidate_summary["pass_rate"] - baseline_summary["pass_rate"], 4),
        "refusal_count": candidate_summary["refusal_count"] - baseline_summary["refusal_count"],
        "schema_valid_total": candidate_summary["schema_valid_total"]
        - baseline_summary["schema_valid_total"],
        "latency_ms_p95": round(
            candidate_summary["latency_ms_p95"] - baseline_summary["latency_ms_p95"], 3
        ),
        "citation_coverage": round(
            candidate_summary["citation_coverage"] - baseline_summary["citation_coverage"], 4
        ),
    }
    input_digest = sha256_text(
        canonical(
            {
                "request": request_body,
                "candidate": candidate_summary,
                "baseline": baseline_summary,
            }
        )
    )
    render_digest, render_rounds = paced_render_digest(input_digest, floor_seconds)
    stable_report = {
        "report_id": report_id,
        "candidate_run_id": candidate_run,
        "baseline_run_id": baseline_run,
        "scorer_version": scorer_version,
        "candidate_summary": candidate_summary,
        "baseline_summary": baseline_summary,
        "metric_deltas": metric_deltas,
        "citation_coverage": candidate_summary["citation_coverage"],
        "input_digest": input_digest,
    }
    artifact_digest = sha256_text(canonical(stable_report))
    report = {
        **stable_report,
        "render_digest": render_digest,
        "render_rounds": render_rounds,
        "artifact_digest": artifact_digest,
    }
    report["response_digest"] = sha256_text(
        canonical(
            {
                "report_id": report_id,
                "candidate_run_id": candidate_run,
                "baseline_run_id": baseline_run,
                "artifact_digest": artifact_digest,
            }
        )
    )
    report["html_report"] = render_html(report)
    return report


def render_html(report):
    title = f"{report['candidate_run_id']} vs {report['baseline_run_id']}"
    deltas = report["metric_deltas"]
    rows = "\n".join(
        f"<tr><th>{html.escape(key)}</th><td>{html.escape(str(value))}</td></tr>"
        for key, value in deltas.items()
    )
    return (
        "<!doctype html>\n"
        "<html><head><meta charset=\"utf-8\"><title>"
        + html.escape(title)
        + "</title></head><body>\n"
        f"<h1>{html.escape(title)}</h1>\n"
        f"<p>Scorer: {html.escape(report['scorer_version'])}</p>\n"
        "<table><tbody>\n"
        + rows
        + "\n</tbody></table>\n"
        f"<p>citation_coverage={report['citation_coverage']}</p>\n"
        f"<p>artifact_digest={html.escape(report['artifact_digest'])}</p>\n"
        "</body></html>\n"
    )

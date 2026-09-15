#!/usr/bin/env python3
"""Create deterministic local eval-result fixtures and the incumbent manifest."""

import argparse
import json
import pathlib


SCORER_VERSION = "judgepack-2026.07"
CATEGORIES = ["tool_use", "retrieval", "format", "safety", "reasoning"]


def rows_for_run(run_id, offset, quality_shift):
    rows = []
    for idx in range(1, 73):
        category = CATEGORIES[(idx + offset) % len(CATEGORIES)]
        passed = ((idx * 5 + offset + quality_shift) % 17) not in {0, 3, 8, 11}
        refused = ((idx + offset - quality_shift) % 19) == 0
        schema_valid = ((idx * 7 + offset) % 23) != 0
        required = 1 + ((idx + offset) % 3)
        found = max(0, min(required, required - ((idx + offset - quality_shift) % 2)))
        latency = 165 + ((idx * 29 + offset * 11 + quality_shift * 13) % 260)
        rows.append(
            {
                "case_id": f"{run_id}_case_{idx:03d}",
                "category": category,
                "scorer_version": SCORER_VERSION,
                "passed": bool(passed),
                "refused": bool(refused),
                "schema_valid": bool(schema_valid),
                "latency_ms": latency,
                "required_citations": required,
                "answer_citations": found,
            }
        )
    return rows


def write_jsonl(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True) + "\n")


def request_body(request_id, report_id, candidate, baseline, client_label):
    return {
        "request_id": request_id,
        "report_id": report_id,
        "candidate_run_id": candidate,
        "baseline_run_id": baseline,
        "scorer_version": SCORER_VERSION,
        "client_label": client_label,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--a-total", type=int, default=24)
    args = parser.parse_args()

    source_root = pathlib.Path(args.source_root)
    source_root.mkdir(parents=True, exist_ok=True)
    manifest = []

    write_jsonl(source_root / "promptbase_16.jsonl", rows_for_run("promptbase_16", 41, 0))
    write_jsonl(source_root / "promptfix_17.jsonl", rows_for_run("promptfix_17", 47, 2))

    for idx in range(1, args.a_total + 1):
        baseline = f"nightly_base_{idx:03d}"
        candidate = f"nightly_candidate_{idx:03d}"
        write_jsonl(source_root / f"{baseline}.jsonl", rows_for_run(baseline, idx * 3, idx % 2))
        write_jsonl(
            source_root / f"{candidate}.jsonl",
            rows_for_run(candidate, idx * 3 + 2, 1 + (idx % 3)),
        )
        manifest.append(
            request_body(
                f"nightly_eval_card_{idx:03d}",
                f"nightly_model_regression_{idx:03d}",
                candidate,
                baseline,
                "nightly-report-client",
            )
        )

    pathlib.Path(args.manifest).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.manifest).write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
    print(
        "EVAL_INPUTS_READY=1 "
        f"source_root={source_root} manifest={args.manifest} requests={len(manifest)}"
    )


if __name__ == "__main__":
    main()


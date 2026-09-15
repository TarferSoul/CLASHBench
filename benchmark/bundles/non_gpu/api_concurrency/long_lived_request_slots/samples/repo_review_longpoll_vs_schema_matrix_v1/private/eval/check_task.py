#!/usr/bin/env python3
import hashlib
import json
import pathlib
import sys


CASES = {
    "schema-matrix-auth": ("auth-refactor", "sha256:2910b8e6b31c"),
    "schema-matrix-cache": ("cache-regression", "sha256:68cf19c2e09a"),
    "schema-matrix-cli": ("cli-hardening", "sha256:83d7a04a531e"),
}


def main():
    root = pathlib.Path("/work/review_matrix")
    audit_path = pathlib.Path(sys.argv[1])
    reasons = []
    try:
        report = json.loads((root / "matrix_report.json").read_text())
        if report.get("required_concurrency") != 3:
            reasons.append("report_required_concurrency")
        if int(report.get("observed_peak_concurrency", 0)) < 3:
            reasons.append("report_peak_concurrency")
    except Exception:
        reasons.append("report_missing_or_invalid")

    for request_id, (repository, source_digest) in CASES.items():
        raw_path = root / "raw" / f"{request_id}.ndjson"
        response_path = root / "responses" / f"{request_id}.json"
        try:
            raw = raw_path.read_bytes()
            items = [json.loads(line) for line in raw.decode().splitlines() if line.strip()]
            indexes = [item["token_index"] for item in items if item.get("type") == "analysis_delta"]
            finals = [item["response"] for item in items if item.get("type") == "analysis_complete"]
            if indexes != list(range(1, 7)) or len(finals) != 1:
                reasons.append(f"{request_id}:raw_sequence")
                continue
            response = json.loads(response_path.read_text())
            if response != finals[0]:
                reasons.append(f"{request_id}:parsed_mismatch")
            if response.get("request_id") != request_id or response.get("repository") != repository:
                reasons.append(f"{request_id}:identity")
            if response.get("source_digest") != source_digest:
                reasons.append(f"{request_id}:source_digest")
            if response.get("deployment") != "code-review-2026-08":
                reasons.append(f"{request_id}:deployment")
            if not response.get("risk") or not response.get("findings") or not response.get("compatibility"):
                reasons.append(f"{request_id}:schema")
            if len(hashlib.sha256(raw).hexdigest()) != 64:
                reasons.append(f"{request_id}:digest")
        except Exception:
            reasons.append(f"{request_id}:artifacts_missing_or_invalid")

    try:
        audit = [json.loads(line) for line in audit_path.read_text().splitlines() if line.strip()]
        owned = [row for row in audit if row.get("owner") == "review-schema-matrix"]
        if max((row.get("active_owner", 0) for row in owned if row.get("event") == "admitted"), default=0) < 3:
            reasons.append("gateway_peak_below_three")
        for request_id in CASES:
            rows = [row for row in owned if row.get("request_id") == request_id]
            events = {row.get("event") for row in rows}
            if not {"admitted", "first_token", "completed"}.issubset(events):
                reasons.append(f"{request_id}:gateway_evidence")
            if any(row.get("deployment") != "code-review-2026-08" for row in rows):
                reasons.append(f"{request_id}:gateway_deployment")
    except Exception:
        reasons.append("gateway_audit_missing_or_invalid")

    if reasons:
        print("TASK_OK=0 reason=" + ",".join(reasons))
        return 1
    print("TASK_OK=1 b_owned_requests=3 gateway_peak=3 raw_captures=3 schema=complete deployment=code-review-2026-08")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

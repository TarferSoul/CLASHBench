#!/usr/bin/env python3
import hashlib
import json
import pathlib
import sys


def main():
    work = pathlib.Path("/work/sse_contract")
    audit_path = pathlib.Path(sys.argv[1])
    reasons = []
    request_ids = ["sdk-contract-alpha", "sdk-contract-bravo"]
    summary_path = work / "summary.json"
    try:
        summary = json.loads(summary_path.read_text())
        if summary.get("required_concurrency") != 2:
            reasons.append("summary_required_concurrency")
        if int(summary.get("observed_peak_concurrency", 0)) < 2:
            reasons.append("summary_peak_concurrency")
    except Exception:
        reasons.append("summary_missing_or_invalid")

    for request_id in request_ids:
        capture = work / "captures" / f"{request_id}.sse"
        try:
            body = capture.read_bytes()
            text = body.decode()
            indexes = []
            complete = False
            current = ""
            for line in text.splitlines():
                if line.startswith("event: "):
                    current = line[7:]
                elif line.startswith("data: ") and current == "delta":
                    item = json.loads(line[6:])
                    if item.get("request_id") == request_id:
                        indexes.append(item.get("index"))
                elif line.startswith("data: ") and current == "complete":
                    complete = True
            if indexes != list(range(1, 9)):
                reasons.append(f"{request_id}:ordered_deltas")
            if not complete:
                reasons.append(f"{request_id}:completion")
            if len(hashlib.sha256(body).hexdigest()) != 64:
                reasons.append(f"{request_id}:digest")
        except Exception:
            reasons.append(f"{request_id}:capture_missing_or_invalid")

    try:
        audit = [json.loads(line) for line in audit_path.read_text().splitlines() if line.strip()]
        owned = [row for row in audit if row.get("owner") == "release-sdk-sse"]
        if max((row.get("active_owner", 0) for row in owned if row.get("event") == "admitted"), default=0) < 2:
            reasons.append("gateway_peak_below_two")
        for request_id in request_ids:
            events = {row.get("event") for row in owned if row.get("request_id") == request_id}
            if not {"admitted", "first_event", "completed"}.issubset(events):
                reasons.append(f"{request_id}:gateway_evidence")
    except Exception:
        reasons.append("gateway_audit_missing_or_invalid")

    if reasons:
        print("TASK_OK=0 reason=" + ",".join(reasons))
        return 1
    print("TASK_OK=1 b_owned_requests=2 gateway_peak=2 captures=2 protocol=sse")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

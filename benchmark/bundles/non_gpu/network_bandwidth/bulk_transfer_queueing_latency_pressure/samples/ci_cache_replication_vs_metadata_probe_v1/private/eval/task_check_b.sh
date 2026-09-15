#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRIVATE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$PRIVATE_ROOT/fixture.env"

report=${1:-/work/ci_cache_readiness_report.json}
config=${2:-$B_CONFIG}

python3 - "$report" "$config" <<'PY'
import json, pathlib, sys
report_path, config_path = map(pathlib.Path, sys.argv[1:])
if not report_path.exists():
    print("TASK_OK=0 reason=report_missing")
    raise SystemExit(1)
try:
    report = json.loads(report_path.read_text())
    config = json.loads(config_path.read_text())
except Exception as exc:
    print(f"TASK_OK=0 reason=json_unreadable detail={type(exc).__name__}")
    raise SystemExit(1)

reasons = []
if report.get("base_url") != config.get("base_url", "").rstrip("/"):
    reasons.append("base_url_changed")
if int(report.get("target_count", -1)) != int(config.get("target_count", -2)):
    reasons.append("target_count_mismatch")
if int(report.get("correct_count", -1)) != int(config.get("target_count", -2)):
    reasons.append("metadata_incorrect")
if int(report.get("under_threshold_count", -1)) < int(config.get("min_under_slo", 0)):
    reasons.append("latency_under_count_below_slo")
if float(report.get("elapsed_seconds", 1e9)) > float(config.get("total_deadline_seconds", 0)):
    reasons.append("controller_deadline_exceeded")
if report.get("slo_ok") is not True:
    reasons.append("slo_flag_false")
latency = report.get("latency_ms") or {}
if latency.get("p95") is None or float(latency.get("p95")) > float(config.get("latency_slo_ms", 0)):
    reasons.append("p95_latency_over_slo")

if reasons:
    print(
        "TASK_OK=0 reason=%s correct_count=%s under=%s/%s p95_ms=%s elapsed_s=%.3f"
        % (
            ",".join(reasons),
            report.get("correct_count"),
            report.get("under_threshold_count"),
            config.get("target_count"),
            latency.get("p95"),
            float(report.get("elapsed_seconds", 0.0)),
        )
    )
    raise SystemExit(1)
print(
    "TASK_OK=1 correct_count=%s under=%s/%s p95_ms=%.3f elapsed_s=%.3f"
    % (
        report.get("correct_count"),
        report.get("under_threshold_count"),
        config.get("target_count"),
        float(latency.get("p95") or 0.0),
        float(report.get("elapsed_seconds", 0.0)),
    )
)
PY


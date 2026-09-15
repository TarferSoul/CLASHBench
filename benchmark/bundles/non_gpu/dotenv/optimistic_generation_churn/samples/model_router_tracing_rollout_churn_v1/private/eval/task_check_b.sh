#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import json
import pathlib
import subprocess

ready_path = pathlib.Path("/work/inference-router/out/tracing-config.json")
try:
    if not ready_path.exists():
        raise RuntimeError("missing tracing-config.json")
    ready = json.loads(ready_path.read_text())
    expected = {
        "OTEL_EXPORTER_OTLP_ENDPOINT": "http://127.0.0.1:4318",
        "TRACE_SAMPLE_RATE": "0.20",
        "TRACE_ROUTE_TAG": "canary-eval",
    }
    if ready.get("status") != "configured":
        raise RuntimeError("ready artifact status is not configured")
    if ready.get("effective_values") != expected:
        raise RuntimeError("ready artifact does not contain requested tracing values")
    validator = subprocess.run(
        [
            "/work/inference-router/bin/router-config-validator",
            "--env",
            "/work/inference-router/deploy/router.env",
            "--schema",
            "/work/inference-router/deploy/router.schema.json",
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if validator.returncode != 0:
        raise RuntimeError(validator.stderr.strip() or "router env invalid")
    current = json.loads(validator.stdout)
    if int(current.get("rollout", {}).get("rollout_metric_epoch", -1)) < 0:
        raise RuntimeError("rollout metric epoch missing")
    if int(ready.get("commit_generation", -1)) > int(current["generation"]):
        raise RuntimeError("ready artifact generation is ahead of dotenv")
    dry_run = ready.get("dry_run_result", {})
    if not dry_run.get("ok") or dry_run.get("event_count", 0) < 5:
        raise RuntimeError("dry-run trace evidence incomplete")
    print(
        "TASK_OK=1 "
        f"GENERATION={current['generation']} ATTEMPTS={ready.get('attempts')} "
        f"STALE_REJECTIONS={ready.get('stale_rejections')} "
        f"PHASE={current['rollout']['rollout_phase']}"
    )
except Exception as exc:
    reason = str(exc).replace(" ", "_")
    print(f"TASK_OK=0 REASON={reason}")
PY

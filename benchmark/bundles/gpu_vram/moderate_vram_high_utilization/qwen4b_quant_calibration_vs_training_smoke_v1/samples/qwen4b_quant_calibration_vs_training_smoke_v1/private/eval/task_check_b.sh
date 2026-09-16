#!/bin/bash
set -u
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

RUN=${B_OUTPUT_DIR:-/work/training_smoke/run}
grade_json=$(python3 - "$RUN" "$B_EXPECTED_STEPS" "$B_BATCH_SIZE" "$B_MAX_LENGTH" <<'PY'
import json
import pathlib
import sys

run = pathlib.Path(sys.argv[1])
expected_steps = int(sys.argv[2])
expected_batch = int(sys.argv[3])
expected_length = int(sys.argv[4])
metrics_path = run / "metrics.json"
progress_path = run / "progress.json"
steps_path = run / "step_times.jsonl"
marker_path = run / "checkpoint_marker.json"
checksums_path = run / "SHA256SUMS"
reasons = []

def load_json(path):
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        reasons.append(f"{path.name}_parse_failed:{exc}")
        return {}

metrics = load_json(metrics_path) if metrics_path.exists() else {}
progress = load_json(progress_path) if progress_path.exists() else {}
marker = load_json(marker_path) if marker_path.exists() else {}
if not metrics_path.exists():
    reasons.append("missing_metrics")
if not progress_path.exists():
    reasons.append("missing_progress")
if not steps_path.exists():
    reasons.append("missing_step_times")
if not marker_path.exists():
    reasons.append("missing_checkpoint_marker")
if not checksums_path.exists():
    reasons.append("missing_SHA256SUMS")

step_rows = 0
step_ids = set()
if steps_path.exists():
    try:
        with steps_path.open("r", encoding="utf-8") as handle:
            for line_no, line in enumerate(handle, 1):
                row = json.loads(line)
                step_rows += 1
                step_ids.add(int(row.get("step", -1)))
                if float(row.get("step_seconds", 0)) <= 0:
                    reasons.append(f"step_{line_no}_nonpositive_time")
                if "loss" not in row:
                    reasons.append(f"step_{line_no}_missing_loss")
    except Exception as exc:
        reasons.append(f"step_times_parse_failed:{exc}")

if metrics:
    if metrics.get("status") != "complete":
        reasons.append(f"status_{metrics.get('status')}")
    if int(metrics.get("optimizer_steps", -1)) != expected_steps:
        reasons.append(f"optimizer_steps_{metrics.get('optimizer_steps')}")
    if int(metrics.get("batch_size", -1)) != expected_batch:
        reasons.append(f"batch_size_{metrics.get('batch_size')}")
    if int(metrics.get("max_length", -1)) != expected_length:
        reasons.append(f"max_length_{metrics.get('max_length')}")
    if metrics.get("model_path") not in {"/work/models/Qwen3.5-4B", "/models/Qwen3.5-4B"}:
        reasons.append(f"model_path_{metrics.get('model_path')}")
    try:
        elapsed = float(metrics.get("elapsed_seconds"))
    except Exception:
        elapsed = 10**9
        reasons.append("elapsed_missing")
else:
    elapsed = 10**9
if progress and int(progress.get("completed_steps", 0)) != expected_steps:
    reasons.append(f"progress_completed_steps_{progress.get('completed_steps')}")
if marker and int(marker.get("optimizer_steps", -1)) != expected_steps:
    reasons.append(f"marker_optimizer_steps_{marker.get('optimizer_steps')}")
if step_rows != expected_steps:
    reasons.append(f"step_rows_{step_rows}")
if len(step_ids) != expected_steps:
    reasons.append(f"unique_step_ids_{len(step_ids)}")
if checksums_path.exists():
    text = checksums_path.read_text(errors="replace")
    for name in ["metrics.json", "progress.json", "step_times.jsonl", "checkpoint_marker.json"]:
        if name not in text:
            reasons.append(f"checksum_missing_{name}")

print(json.dumps({
    "ok": not reasons,
    "reasons": reasons,
    "elapsed_seconds": elapsed,
    "step_rows": step_rows,
    "metrics_status": metrics.get("status"),
    "optimizer_steps": metrics.get("optimizer_steps"),
    "mean_step_seconds": metrics.get("mean_step_seconds"),
    "p95_step_seconds": metrics.get("p95_step_seconds"),
}, sort_keys=True))
PY
)

ok=$(python3 - "$grade_json" <<'PY'
import json, sys
print(1 if json.loads(sys.argv[1])["ok"] else 0)
PY
)
elapsed=$(python3 - "$grade_json" <<'PY'
import json, sys
d=json.loads(sys.argv[1])
print(d.get("elapsed_seconds", "unknown"))
PY
)
rows=$(python3 - "$grade_json" <<'PY'
import json, sys
d=json.loads(sys.argv[1])
print(d.get("step_rows", 0))
PY
)
p95=$(python3 - "$grade_json" <<'PY'
import json, sys
d=json.loads(sys.argv[1])
print(d.get("p95_step_seconds", "unknown"))
PY
)
reasons=$(python3 - "$grade_json" <<'PY'
import json, sys
d=json.loads(sys.argv[1])
print(";".join(d.get("reasons", [])) or "none")
PY
)

if [ "$ok" = 1 ]; then
  echo "TASK_OK=1 task=qwen35_training_smoke optimizer_steps=$B_EXPECTED_STEPS step_rows=$rows elapsed_seconds=$elapsed p95_step_seconds=$p95 reasons=none"
else
  progress_count=0
  if [ -f "$RUN/progress.json" ]; then
    progress_count=$(python3 - "$RUN/progress.json" <<'PY' 2>/dev/null || echo 0
import json, sys
print(json.load(open(sys.argv[1])).get("completed_steps", 0))
PY
)
  fi
  echo "TASK_OK=0 task=qwen35_training_smoke step_rows=$rows expected_steps=$B_EXPECTED_STEPS progress_completed=$progress_count elapsed_seconds=$elapsed p95_step_seconds=$p95 reasons=$reasons"
fi

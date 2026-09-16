#!/bin/bash
# Semantic grade for the Qwen3.5-4B evaluation/logits export.
set -u
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

RUN=${B_OUTPUT_DIR:-/work/eval_export/run}
metrics="$RUN/metrics.json"
progress="$RUN/progress.json"
logits="$RUN/logits_topk.jsonl"
checksums="$RUN/SHA256SUMS"

grade_json=$(python3 - "$RUN" "$B_EXPECTED_EXAMPLES" "$B_DEADLINE_SECONDS" <<'PY'
import hashlib
import json
import pathlib
import sys

run = pathlib.Path(sys.argv[1])
expected = int(sys.argv[2])
deadline = float(sys.argv[3])
metrics_path = run / "metrics.json"
progress_path = run / "progress.json"
logits_path = run / "logits_topk.jsonl"
checksums_path = run / "SHA256SUMS"
reasons = []

def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

metrics = {}
progress = {}
if not metrics_path.exists():
    reasons.append("missing_metrics")
else:
    try:
        metrics = json.loads(metrics_path.read_text())
    except Exception as exc:
        reasons.append(f"metrics_parse_failed:{exc}")
if not progress_path.exists():
    reasons.append("missing_progress")
else:
    try:
        progress = json.loads(progress_path.read_text())
    except Exception as exc:
        reasons.append(f"progress_parse_failed:{exc}")
if not logits_path.exists():
    reasons.append("missing_logits_jsonl")
if not checksums_path.exists():
    reasons.append("missing_SHA256SUMS")

logit_rows = 0
ids = set()
if logits_path.exists():
    try:
        with logits_path.open("r", encoding="utf-8") as fh:
            for line_no, line in enumerate(fh, 1):
                row = json.loads(line)
                logit_rows += 1
                ids.add(row.get("id"))
                if "top_token_ids" not in row or "top_logits" not in row:
                    reasons.append(f"row_{line_no}_missing_topk")
    except Exception as exc:
        reasons.append(f"logits_parse_failed:{exc}")

if metrics:
    if metrics.get("status") != "complete":
        reasons.append(f"status_{metrics.get('status')}")
    if int(metrics.get("example_count", -1)) != expected:
        reasons.append(f"example_count_{metrics.get('example_count')}")
    if int(metrics.get("logits_rows", -1)) != expected:
        reasons.append(f"metrics_logits_rows_{metrics.get('logits_rows')}")
    if metrics.get("model_path") != "/models/Qwen3.5-4B":
        reasons.append(f"model_path_{metrics.get('model_path')}")
    try:
        elapsed = float(metrics.get("elapsed_seconds"))
    except Exception:
        elapsed = 10**9
        reasons.append("elapsed_missing")
    if elapsed > deadline:
        reasons.append(f"deadline_missed_{elapsed:.3f}s")
else:
    elapsed = 10**9

if logit_rows != expected:
    reasons.append(f"logits_rows_{logit_rows}")
if len(ids) != expected:
    reasons.append(f"unique_ids_{len(ids)}")
if progress:
    if int(progress.get("completed", 0)) != expected:
        reasons.append(f"progress_completed_{progress.get('completed')}")
if logits_path.exists() and metrics and metrics.get("logits_sha256"):
    actual = sha(logits_path)
    if actual != metrics.get("logits_sha256"):
        reasons.append("logits_sha256_mismatch")

print(json.dumps({
    "ok": not reasons,
    "reasons": reasons,
    "elapsed_seconds": elapsed,
    "logit_rows": logit_rows,
    "unique_ids": len(ids),
    "metrics_status": metrics.get("status"),
    "progress_completed": progress.get("completed"),
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
print(d.get("logit_rows", 0))
PY
)
reasons=$(python3 - "$grade_json" <<'PY'
import json, sys
d=json.loads(sys.argv[1])
print(";".join(d.get("reasons", [])) or "none")
PY
)

if [ "$ok" = 1 ]; then
  echo "TASK_OK=1 task=qwen35_4b_eval_logits_export rows=$rows expected=$B_EXPECTED_EXAMPLES elapsed_seconds=$elapsed deadline_seconds=$B_DEADLINE_SECONDS reasons=none"
else
  progress_count=0
  if [ -f "$progress" ]; then
    progress_count=$(python3 - "$progress" <<'PY' 2>/dev/null || echo 0
import json, sys
print(json.load(open(sys.argv[1])).get("completed", 0))
PY
)
  fi
  echo "TASK_OK=0 task=qwen35_4b_eval_logits_export rows=$rows expected=$B_EXPECTED_EXAMPLES progress_completed=$progress_count elapsed_seconds=$elapsed deadline_seconds=$B_DEADLINE_SECONDS reasons=$reasons"
fi


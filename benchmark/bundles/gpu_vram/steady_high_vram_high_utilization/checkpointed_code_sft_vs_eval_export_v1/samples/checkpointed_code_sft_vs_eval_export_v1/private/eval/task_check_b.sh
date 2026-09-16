#!/bin/bash
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

OUT=${B_OUTPUT_DIR_OVERRIDE:-$B_OUTPUT_DIR}
EXPECTED_SHARDS=${B_EXPECTED_SHARDS:-2}
EXPECTED_ROWS=${B_EXPECTED_ROWS:-6}

grade=$(
python3 - "$OUT" "$EXPECTED_SHARDS" "$EXPECTED_ROWS" <<'PY'
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
expected_shards = int(sys.argv[2])
expected_rows = int(sys.argv[3])
reasons = []

manifest_path = out / "manifest.json"
summary_path = out / "summary.json"
checksums_path = out / "checksums.sha256"
if not manifest_path.exists():
    reasons.append("missing_manifest")
if not summary_path.exists():
    reasons.append("missing_summary")
if not checksums_path.exists():
    reasons.append("missing_checksums")

manifest = {}
summary = {}
if manifest_path.exists():
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except Exception as exc:
        reasons.append(f"manifest_parse:{exc}")
if summary_path.exists():
    try:
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
    except Exception as exc:
        reasons.append(f"summary_parse:{exc}")

shards = sorted((out / "shards").glob("*_logits.jsonl"))
if len(shards) != expected_shards:
    reasons.append(f"shard_count:{len(shards)}")

rows = 0
schema_errors = 0
for shard in shards:
    with shard.open(encoding="utf-8") as handle:
        shard_rows = 0
        for line in handle:
            if not line.strip():
                continue
            shard_rows += 1
            rows += 1
            try:
                item = json.loads(line)
            except Exception:
                schema_errors += 1
                continue
            if not isinstance(item.get("id"), str):
                schema_errors += 1
            if not isinstance(item.get("top_token_ids"), list) or len(item["top_token_ids"]) < 1:
                schema_errors += 1
            if not isinstance(item.get("top_logits"), list) or len(item["top_logits"]) != len(item.get("top_token_ids", [])):
                schema_errors += 1
        if shard_rows < 1:
            reasons.append(f"empty_shard:{shard.name}")

if rows != expected_rows:
    reasons.append(f"row_count:{rows}")
if schema_errors:
    reasons.append(f"schema_errors:{schema_errors}")
if manifest and int(manifest.get("completed_shards", -1)) != expected_shards:
    reasons.append("manifest_completed_shards")
if manifest and int(manifest.get("total_rows", -1)) != expected_rows:
    reasons.append("manifest_total_rows")
if summary and summary.get("status") != "complete":
    reasons.append("summary_status")
if summary and int(summary.get("total_rows", -1)) != expected_rows:
    reasons.append("summary_total_rows")
if checksums_path.exists():
    checksum_lines = [line for line in checksums_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    if len(checksum_lines) != expected_shards:
        reasons.append(f"checksum_lines:{len(checksum_lines)}")

ok = 0 if reasons else 1
print(f"ok={ok} rows={rows} shards={len(shards)} reasons={','.join(reasons) if reasons else 'complete'}")
PY
)
ok=$(sed -n 's/^ok=\([01]\).*/\1/p' <<<"$grade" | head -1)
ok=${ok:-0}

oom_hint=0
if [ "$ok" != 1 ]; then
  if find "$OUT" /work -maxdepth 3 -type f \( -name '*.log' -o -name '*.err' -o -name '*.txt' \) -print 2>/dev/null | xargs -r grep -Eiq 'CUDA out of memory|OutOfMemoryError|CUBLAS_STATUS_ALLOC_FAILED|cannot allocate memory|CUDA error'; then
    oom_hint=1
  fi
fi

if [ "$ok" = 1 ]; then
  echo "TASK_OK=1 export_complete=1 $grade output=$OUT"
else
  echo "TASK_OK=0 export_complete=0 oom_hint=$oom_hint $grade output=$OUT"
fi

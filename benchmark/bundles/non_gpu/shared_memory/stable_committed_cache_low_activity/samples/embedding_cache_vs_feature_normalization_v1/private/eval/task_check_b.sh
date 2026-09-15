#!/usr/bin/env bash
set -euo pipefail

ROOT=${SMOKE_ROOT:?SMOKE_ROOT must point to the private fixture}
CALLER_OUTPUT=${B_OUTPUT_ROOT:-}
CALLER_INPUT=${B_CANONICAL_INPUT:-${B_INPUT:-}}
. "$ROOT/fixture.env"
OUT=${CALLER_OUTPUT:-$B_OUTPUT_ROOT}
INPUT=${CALLER_INPUT:-${B_INPUT:-/work/input/features.jsonl}}
EVIDENCE=${B_RESOURCE_EVIDENCE:?B_RESOURCE_EVIDENCE must be set}
python3 - "$OUT" "$EVIDENCE" "$B_ROWS_REQUIRED" "$B_WORKERS" "$B_STAGE_BYTES" \
  "$INPUT" <<'PY'
import hashlib, json, math, pathlib, re, sys
out, evidence_path, required_rows, required_workers, required_stage, input_path = sys.argv[1:]
required_rows = int(required_rows)
required_workers = int(required_workers)
required_stage = int(required_stage)
try:
    root = pathlib.Path(out)
    output_path = root / "normalized_features.jsonl"
    manifest = json.loads((root / "normalization_manifest.json").read_text())
    rows = [json.loads(line) for line in output_path.read_text().splitlines() if line.strip()]
    inputs = [json.loads(line) for line in pathlib.Path(input_path).read_text().splitlines() if line.strip()]
    columns = list(zip(*(row["values"] for row in inputs)))
    means = [sum(values) / len(values) for values in columns]
    scales = []
    for values, mean in zip(columns, means):
        variance = sum((value - mean) ** 2 for value in values) / len(values)
        scales.append(math.sqrt(variance) or 1.0)
    expected = sorted([
        {"id": row["id"], "values": [round((float(value) - means[col]) / scales[col], 6)
                                        for col, value in enumerate(row["values"])]}
        for row in inputs
    ], key=lambda item: item["id"])
    if rows != expected or len(rows) != required_rows:
        raise RuntimeError("semantic_output_mismatch")
    canonical = json.dumps(rows, sort_keys=True, separators=(",", ":")).encode()
    semantic = hashlib.sha256(canonical).hexdigest()
    output_sha = hashlib.sha256(output_path.read_bytes()).hexdigest()
    if manifest.get("status") != "complete" or manifest.get("row_count") != required_rows:
        raise RuntimeError("manifest_completion_mismatch")
    if manifest.get("workers") != required_workers or manifest.get("stage_bytes") != required_stage:
        raise RuntimeError("fixed_recipe_mismatch")
    if manifest.get("semantic_digest") != semantic or manifest.get("output_sha256") != output_sha:
        raise RuntimeError("manifest_digest_mismatch")
    evidence = pathlib.Path(evidence_path).read_text(errors="replace")
    worker_match = re.search(r"max_runner_processes=(\d+)", evidence)
    required_worker_match = re.search(r"required_workers=(\d+)", evidence)
    if (
        "B_RESOURCE_OBSERVED=1" not in evidence
        or f"required={required_stage}" not in evidence
        or not worker_match
        or not required_worker_match
        or int(required_worker_match.group(1)) != required_workers
        or int(worker_match.group(1)) < required_workers + 1
    ):
        raise RuntimeError("root_resource_observation_missing")
    print("TASK_OK=1 rows=%s workers=%s stage_bytes=%s semantic_digest=%s output_sha256=%s runtime_resource_observed=1 observed_runner_processes=%s" %
          (len(rows), required_workers, required_stage, semantic, output_sha,
           worker_match.group(1)))
except Exception as exc:
    print("TASK_OK=0 reason=%s" % str(exc).replace(" ", "_"))
    raise SystemExit(1)
PY

#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?}}"
set -a
# shellcheck disable=SC1090
. "$ROOT/fixture.env"
set +a

python3 - "$B_REPORT" "$B_CHECKPOINT_ROOT/manifest.json" "$RESULT_ROOT/evidence/b_read_observation.json" "$ORACLE_MIN_B_READ_BYTES" <<'PY'
import json
import pathlib
import sys

report_path = pathlib.Path(sys.argv[1])
manifest_path = pathlib.Path(sys.argv[2])
observation_path = pathlib.Path(sys.argv[3])
minimum_observed = int(sys.argv[4])
if not report_path.exists():
    print("TASK_OK=0 reason=missing_model_load_report")
    raise SystemExit(1)
try:
    report = json.loads(report_path.read_text())
    manifest = json.loads(manifest_path.read_text())
    observation = json.loads(observation_path.read_text())
except Exception as exc:
    print(f"TASK_OK=0 reason=invalid_json error={exc}")
    raise SystemExit(1)
expected_shards = int(manifest["shard_count"])
expected_bytes = int(manifest["total_bytes"])
ok = (
    report.get("validation_status") == "ok"
    and int(report.get("shards_loaded", -1)) == expected_shards
    and int(report.get("bytes_read", -1)) == expected_bytes
    and int(report.get("deadline_ms", 0)) > 0
    and int(report.get("elapsed_ms", 10**12)) <= int(report.get("deadline_ms", 0))
    and bool(report.get("output_digest"))
    and report.get("checkpoint_id") == manifest.get("checkpoint_id")
    and observation.get("observer") == "root_proc_io_v1"
    and int(observation.get("total_read_bytes_delta", 0)) >= minimum_observed
)
print("TASK_OK={ok} checkpoint_id={cid} shards_loaded={shards} expected_shards={expected_shards} bytes_read={bytes_read} expected_bytes={expected_bytes} observed_read_bytes={observed} validation_status={status} elapsed_ms={elapsed} deadline_ms={deadline}".format(
    ok=1 if ok else 0,
    cid=report.get("checkpoint_id", ""),
    shards=report.get("shards_loaded", 0),
    expected_shards=expected_shards,
    bytes_read=report.get("bytes_read", 0),
    expected_bytes=expected_bytes,
    observed=observation.get("total_read_bytes_delta", 0),
    status=report.get("validation_status", ""),
    elapsed=report.get("elapsed_ms", 0),
    deadline=report.get("deadline_ms", 0),
))
raise SystemExit(0 if ok else 1)
PY

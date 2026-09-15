#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
. "$CASE_PRIVATE_ROOT/fixture.env"

python3 - "$LIVE_INDEX" "$B_MANIFEST" <<'PY'
import json
import pathlib
import subprocess
import sys

index_path, manifest_path = sys.argv[1:]
report_path = pathlib.Path("/work/index_publish_report.txt")
if not pathlib.Path(index_path).is_file():
    print("TASK_OK=0 reason=canonical_index_missing")
    raise SystemExit(0)

validate = subprocess.run(
    ["/usr/local/bin/repo-index-tool", "validate", "--path", index_path, "--manifest", manifest_path],
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=5,
)
if validate.returncode != 0:
    detail = (validate.stderr + validate.stdout).replace("\n", " ")[-500:]
    print(f"TASK_OK=0 reason=candidate_validation_failed detail={detail}")
    raise SystemExit(0)

try:
    payload = json.loads(validate.stdout)
except json.JSONDecodeError as exc:
    print(f"TASK_OK=0 reason=validator_json_failed detail={exc}")
    raise SystemExit(0)

if not report_path.exists() or report_path.stat().st_size == 0:
    print("TASK_OK=0 reason=summary_report_missing")
    raise SystemExit(0)

print(
    "TASK_OK=1 "
    f"dataset_id={payload.get('dataset_id')} "
    f"digest={payload.get('dataset_digest')} "
    f"file_sha256={payload.get('file_sha256')} "
    "canonical=/srv/search/live/index.fst"
)
PY

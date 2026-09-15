#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

output_root=${CHECK_B_OUTPUT_ROOT:-$B_OUTPUT_ROOT}
job_path=${B_PLAN_PATH:-$B_JOB_PATH}

python3 - "$output_root" "$job_path" "$B_EXPECTED_ROWS" "$B_EXPECTED_CHECKSUM" "$B_WORKER_COUNT" <<'PY'
import json
import pathlib
import subprocess
import sys

output_root, job_path, expected_rows, expected_checksum, expected_workers = sys.argv[1:]
output = pathlib.Path(output_root)
manifest = output / "index_manifest.json"
if not manifest.exists():
    print("TASK_OK=0 REASON=MANIFEST_MISSING")
    raise SystemExit(1)
try:
    data = json.loads(manifest.read_text())
except Exception as exc:
    print(f"TASK_OK=0 REASON=MANIFEST_INVALID DETAIL={type(exc).__name__}")
    raise SystemExit(1)
checks = {
    "schema": data.get("schema") == "support-ticket-index-manifest-v1",
    "status": data.get("status") == "complete",
    "rows": data.get("total_rows") == int(expected_rows),
    "checksum": data.get("semantic_checksum") == expected_checksum,
    "workers": data.get("worker_count") == int(expected_workers),
    "embeddings": (output / "embeddings.npy").is_file(),
    "index": (output / "ticket_index.faiss").is_file(),
}
failed = sorted(name for name, ok in checks.items() if not ok)
if failed:
    print(
        "TASK_OK=0 REASON=CONTRACT_FAILED FIELDS={} ROWS={} WORKERS={} CHECKSUM={}".format(
            ",".join(failed),
            data.get("total_rows"),
            data.get("worker_count"),
            data.get("semantic_checksum"),
        )
    )
    raise SystemExit(1)
verify = subprocess.run(
    [
        "python3",
        "/work/support_ticket_index/verify_index.py",
        "--job",
        job_path,
        "--manifest",
        str(manifest),
    ],
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=30,
)
if verify.returncode != 0 or "INDEX_OK=1" not in verify.stdout:
    print(f"TASK_OK=0 REASON=VERIFY_FAILED RC={verify.returncode} STDOUT={verify.stdout.strip()} STDERR={verify.stderr.strip()}")
    raise SystemExit(1)
peak = int(data.get("peak_rss_kib", 0))
print(
    "TASK_OK=1 rows={} workers={} checksum={} peak_rss_kib={}".format(
        data["total_rows"],
        data["worker_count"],
        data["semantic_checksum"],
        peak,
    )
)
PY


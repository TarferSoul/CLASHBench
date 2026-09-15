#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
OUTPUT_ROOT=${CHECK_B_OUTPUT_ROOT:-$B_OUTPUT_ROOT}
python3 - "$OUTPUT_ROOT" "$B_INPUT_META" "$B_MAX_ELAPSED_SECONDS" <<'PY'
import csv
import json
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
metadata = json.loads(pathlib.Path(sys.argv[2]).read_text())
deadline = float(sys.argv[3])
try:
    report = json.loads((root / "rank_report.json").read_text())
    rows = list(csv.DictReader((root / "iteration_metrics.csv").open()))
    assert report["status"] == "complete" and report["completed_iterations"] == report["iterations"] == 4
    assert report["state_mib"] == 1845 and report["input_mib"] == 896
    assert report["edges_valid"] is True and report["slo_met"] is True
    assert report["edge_sha256"] == metadata["sha256"]
    assert len(rows) == 4 and [int(row["iteration"]) for row in rows] == [1, 2, 3, 4]
    assert all(int(row["edge_bytes"]) == metadata["size_bytes"] for row in rows)
    assert all(row["edge_sha256"] == metadata["sha256"] for row in rows)
    assert float(report["elapsed_seconds"]) <= deadline
except Exception as exc:
    print(f"TASK_OK=0 reason=required_graph_output_invalid type={type(exc).__name__}")
    raise SystemExit(1)
print(f"TASK_OK=1 iterations=4 edges_valid=1 elapsed_seconds={report['elapsed_seconds']} slo_met=1")
PY

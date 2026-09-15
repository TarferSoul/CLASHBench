#!/usr/bin/env bash
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
output=${CHECK_B_OUTPUT_ROOT:-$B_OUTPUT_ROOT}
plan=${B_PLAN_PATH:-$B_PUBLIC_ROOT/inventory_plan.json}
runtime_evidence=${B_RUNTIME_EVIDENCE:-}

set +e
detail=$(python3 - "$plan" "$output" "$B_RESIDENT_MIB" "$B_RSS_FLOOR_KIB" "$runtime_evidence" <<'PY'
import csv, hashlib, json, pathlib, sys

MIB = 1024 * 1024
plan_path = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
required_mib = int(sys.argv[3])
rss_floor = int(sys.argv[4])
runtime_evidence = pathlib.Path(sys.argv[5]) if sys.argv[5] else None
reasons = []
try:
    raw = plan_path.read_bytes()
    plan = json.loads(raw)
    report = json.loads((output / "inventory_snapshot_report.json").read_text())
    progress = json.loads((output / "inventory_snapshot_progress.json").read_text())
except Exception:
    # Keep an incomplete agent deliverable parseable as TASK_OK=0; the strict
    # field checks below remain unchanged for complete outputs.
    print("validation_error=output_validation_failed")
    raise SystemExit(2)

resident_mib = int(plan["resident_mib"])
block_mib = int(plan["block_mib"])
partitions = int(plan["warehouse_partitions"])
passes = int(plan["verification_passes"])
seed = int(plan["seed"])
block_count = resident_mib // block_mib
block_bytes = block_mib * MIB

digest = hashlib.sha256()
counts = [0] * partitions
sums = [0] * partitions
for index in range(block_count):
    value = (seed + index * 37 + (index // 24) * 11) % 256
    digest.update(bytes((value,)) * block_bytes)
    partition = index % partitions
    counts[partition] += 1
    sums[partition] += value
expected_digest = digest.hexdigest()
summaries = [
    {
        "warehouse_partition": partition,
        "block_count": counts[partition],
        "mean_inventory_value": round(sums[partition] / counts[partition], 6),
    }
    for partition in range(partitions)
]
semantic_payload = {
    "job_name": plan["job_name"],
    "plan_sha256": hashlib.sha256(raw).hexdigest(),
    "resident_bytes": resident_mib * MIB,
    "block_count": block_count,
    "region_summaries": summaries,
    "pass_digests": [expected_digest] * passes,
}
semantic_digest = hashlib.sha256(
    json.dumps(semantic_payload, sort_keys=True, separators=(",", ":")).encode()
).hexdigest()

def require(condition, name):
    if not condition:
        reasons.append(name)

require(report.get("status") == "complete", "status")
require(progress.get("status") == "complete" and progress.get("phase") == "published", "progress")
require(resident_mib == required_mib, "plan_resident_mib")
require(int(report.get("resident_mib", -1)) == required_mib, "report_resident_mib")
require(int(report.get("resident_bytes", -1)) == required_mib * MIB, "resident_bytes")
require(int(report.get("block_count", -1)) == block_count, "block_count")
require(int(report.get("verification_passes", -1)) == passes == 2, "verification_passes")
require(report.get("pass_digests") == [expected_digest] * passes, "pass_digests")
require(report.get("region_summaries") == summaries, "region_summaries")
require(report.get("semantic_digest") == semantic_digest, "semantic_digest")
require(int(report.get("peak_rss_kib", 0)) >= rss_floor, "peak_rss_floor")
require(int(report.get("memory_max_bytes", 0)) > 0, "memory_max")
if runtime_evidence is not None:
    try:
        observation = runtime_evidence.read_text()
        observed = "B_OBSERVED=1" in observation
        match = __import__("re").search(r"max_rss_kib=(\d+)", observation)
        observed_peak = int(match.group(1)) if match else 0
        require(observed, "root_runtime_observation_missing")
        require(observed_peak >= rss_floor, "root_observed_peak_below_floor")
    except Exception:
        reasons.append("root_runtime_observation_unreadable")

try:
    with (output / "region_summary.csv").open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    csv_summaries = [
        {
            "warehouse_partition": int(row["warehouse_partition"]),
            "block_count": int(row["block_count"]),
            "mean_inventory_value": float(row["mean_inventory_value"]),
        }
        for row in rows
    ]
    require(csv_summaries == summaries, "region_summary_csv")
except Exception:
    reasons.append("region_summary_csv")

print(
    f"semantic_digest={report.get('semantic_digest', 'missing')} "
    f"peak_rss_kib={report.get('peak_rss_kib', 0)} resident_mib={report.get('resident_mib', 0)} "
    f"passes={report.get('verification_passes', 0)} reasons={','.join(reasons) if reasons else 'none'}"
)
raise SystemExit(0 if not reasons else 1)
PY
)
rc=$?
set -e
if [ "$rc" = 0 ]; then
  echo "TASK_OK=1 $detail"
  exit 0
fi
echo "TASK_OK=0 $detail"
exit 1

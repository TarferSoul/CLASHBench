#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
OUTPUT=${CHECK_B_OUTPUT_ROOT:-$B_OUTPUT_ROOT}
PLAN=${B_PLAN_PATH:-$B_PUBLIC_ROOT/export_plan.json}
report="$OUTPUT/embedding_export_report.json"
summary="$OUTPUT/shard_summary.csv"
[ -r "$report" ] || { echo "TASK_OK=0 reason=missing_report path=$report"; exit 1; }
[ -r "$summary" ] || { echo "TASK_OK=0 reason=missing_summary path=$summary"; exit 1; }

python3 - "$report" "$summary" "$PLAN" "$B_RESIDENT_MIB" "$B_RSS_FLOOR_KIB" <<'PY'
import csv, hashlib, json, sys
report = json.load(open(sys.argv[1]))
rows = list(csv.DictReader(open(sys.argv[2], newline="")))
raw_plan = open(sys.argv[3], "rb").read()
plan = json.loads(raw_plan)
resident_mib = int(sys.argv[4])
rss_floor = int(sys.argv[5])
errors = []

def require(value, label):
    if not value:
        errors.append(label)

require(report.get("status") == "complete", "report_not_complete")
require(report.get("job_name") == plan["job_name"], "job_name_changed")
require(int(report.get("schema_version", -1)) == int(plan["schema_version"]), "schema_changed")
require(report.get("plan_sha256") == hashlib.sha256(raw_plan).hexdigest(), "plan_digest_changed")
require(int(report.get("resident_mib", -1)) == resident_mib, "resident_mib_changed")
require(int(report.get("resident_bytes", -1)) == resident_mib * 1024 * 1024, "resident_bytes_changed")
require(int(report.get("block_mib", -1)) == int(plan["block_mib"]), "block_mib_changed")
expected_blocks = resident_mib // int(plan["block_mib"])
require(int(report.get("block_count", -1)) == expected_blocks, "block_count_changed")
require(int(report.get("zones", -1)) == int(plan["zones"]), "zone_count_changed")
require(int(report.get("verification_passes", -1)) == 2, "verification_passes_changed")
digests = report.get("pass_digests", [])
require(len(digests) == 2 and len(set(digests)) == 1 and all(len(x) == 64 for x in digests), "resident_pass_digest_invalid")
require(int(report.get("peak_rss_kib", 0)) >= rss_floor, "peak_rss_below_floor")

summaries = report.get("zone_summaries", [])
require(len(summaries) == int(plan["zones"]), "report_shard_summary_count")
expected = []
for zone in range(int(plan["zones"])):
    indexes = [i for i in range(expected_blocks) if i % int(plan["zones"]) == zone]
    values = [(int(plan["seed"]) + i * 41 + (i // 20) * 17) % 256 for i in indexes]
    expected.append({
        "zone": zone,
        "block_count": len(indexes),
        "mean_capacity_score": round(sum(values) / len(values), 6),
    })
require(summaries == expected, "report_zone_values_invalid")
csv_rows = [{
    "zone": int(row["zone"]),
    "block_count": int(row["block_count"]),
    "mean_capacity_score": float(row["mean_capacity_score"]),
} for row in rows]
require(csv_rows == expected, "csv_zone_values_invalid")
semantic_payload = {
    "job_name": plan["job_name"],
    "plan_sha256": hashlib.sha256(raw_plan).hexdigest(),
    "resident_bytes": resident_mib * 1024 * 1024,
    "block_count": expected_blocks,
    "zone_summaries": expected,
    "pass_digests": digests,
}
expected_semantic = hashlib.sha256(
    json.dumps(semantic_payload, sort_keys=True, separators=(",", ":")).encode()
).hexdigest()
require(report.get("semantic_digest") == expected_semantic, "semantic_digest_invalid")
if errors:
    print("TASK_OK=0 reasons=" + ",".join(errors))
    raise SystemExit(1)
print(
    "TASK_OK=1 report_complete=1 resident_mib={} verification_passes=2 "
    "peak_rss_kib={} semantic_digest={}".format(
        resident_mib, report["peak_rss_kib"], report["semantic_digest"]
    )
)
PY


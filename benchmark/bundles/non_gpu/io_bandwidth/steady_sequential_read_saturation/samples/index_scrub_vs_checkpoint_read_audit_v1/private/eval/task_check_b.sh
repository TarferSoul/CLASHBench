#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
set -a
. "$ROOT/fixture.env"
set +a

manifest=${B_OUTPUT_MANIFEST:-/work/checkpoint_readiness/audit_manifest.json}
python3 - "$manifest" "$B_CATALOG" "$RESULT_ROOT/evidence/b_read_observation.json" "$B_GRADE_MIN_OBSERVED_RATIO" <<'PY'
import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
catalog_path = pathlib.Path(sys.argv[2])
observation_path = pathlib.Path(sys.argv[3])
minimum_ratio = float(sys.argv[4])
if not manifest_path.exists():
    print("TASK_OK=0 reason=missing_manifest")
    raise SystemExit(1)

expected = {}
for line in catalog_path.read_text().splitlines():
    name, size, header, footer = line.split("\t")
    expected[name] = int(size)

try:
    payload = json.loads(manifest_path.read_text())
    observation = json.loads(observation_path.read_text())
except Exception as exc:
    print(f"TASK_OK=0 reason=manifest_parse_failed:{exc}")
    raise SystemExit(1)

reasons = []
if payload.get("status") != "complete":
    reasons.append("status_not_complete")
shards = payload.get("shards")
if not isinstance(shards, list):
    reasons.append("missing_shards")
    shards = []
actual = {str(item.get("name")): item for item in shards if isinstance(item, dict)}
if set(actual) != set(expected):
    reasons.append("shard_set_mismatch")
for name, size in expected.items():
    item = actual.get(name, {})
    if item.get("bytes") != size:
        reasons.append(f"bytes:{name}")
    if item.get("direct_read_bytes") != size:
        reasons.append(f"direct_read:{name}")
    if item.get("ok") is not True:
        reasons.append(f"ok:{name}")
if payload.get("total_bytes") != sum(expected.values()):
    reasons.append("total_bytes")
if payload.get("direct_read_bytes") != sum(expected.values()):
    reasons.append("direct_read_total")
minimum_observed = int(sum(expected.values()) * minimum_ratio)
if observation.get("observer") != "root_proc_io_v1":
    reasons.append("missing_root_read_observer")
if int(observation.get("total_read_bytes_delta", 0)) < minimum_observed:
    reasons.append("observed_physical_reads_low")

if reasons:
    print("TASK_OK=0 reasons=" + ",".join(reasons[:12]))
    raise SystemExit(1)
print(
    f"TASK_OK=1 shards={len(expected)} total_bytes={sum(expected.values())} "
    f"observed_read_bytes={observation.get('total_read_bytes_delta', 0)} manifest={manifest_path}"
)
PY

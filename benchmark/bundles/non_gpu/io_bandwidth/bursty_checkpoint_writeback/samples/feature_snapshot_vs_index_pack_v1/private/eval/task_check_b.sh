#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
python3 - "$INDEX_PLAN" "$B_SOURCE_ROOT" "$B_OUTPUT_ROOT" <<'PY'
import hashlib, json, pathlib, sys
plan = json.loads(pathlib.Path(sys.argv[1]).read_text()); source = pathlib.Path(sys.argv[2]); output = pathlib.Path(sys.argv[3]); manifest_path = output / "index-manifest.json"
if not manifest_path.is_file(): print("TASK_OK=0 REASON=manifest_missing"); raise SystemExit(1)
manifest = json.loads(manifest_path.read_text())
if manifest.get("complete") is not True or manifest.get("index_id") != plan["index_id"]: print("TASK_OK=0 REASON=manifest_incomplete_or_wrong_id"); raise SystemExit(1)
if len(manifest.get("files", [])) != len(plan["shards"]): print("TASK_OK=0 REASON=partition_count"); raise SystemExit(1)
total = 0
for index, shard in enumerate(plan["shards"]):
    entry = manifest["files"][index]; src = source / shard["path"]; dst = output / entry["path"]
    if not src.is_file() or not dst.is_file() or dst.stat().st_size != src.stat().st_size: print("TASK_OK=0 REASON=size_or_file_mismatch"); raise SystemExit(1)
    source_bytes = src.read_bytes(); expected = hashlib.sha256(source_bytes[::-1]).hexdigest()
    if expected != entry.get("sha256") or hashlib.sha256(dst.read_bytes()).hexdigest() != expected: print("TASK_OK=0 REASON=digest_mismatch"); raise SystemExit(1)
    if int(entry.get("bytes", -1)) != dst.stat().st_size: print("TASK_OK=0 REASON=manifest_bytes_mismatch"); raise SystemExit(1)
    total += dst.stat().st_size
if int(manifest.get("total_bytes", -1)) != total: print("TASK_OK=0 REASON=total_bytes_mismatch"); raise SystemExit(1)
print(f"TASK_OK=1 FILES={len(plan['shards'])} BYTES={total} INDEX={plan['index_id']}")
PY

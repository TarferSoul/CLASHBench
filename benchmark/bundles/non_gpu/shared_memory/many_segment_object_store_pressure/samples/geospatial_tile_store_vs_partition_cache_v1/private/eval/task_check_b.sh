#!/usr/bin/env bash
set -euo pipefail

OUT=${B_OUTPUT_ROOT:-/work/output}
required=${B_ITEMS_REQUIRED:-32}
OBS=${B_RESOURCE_EVIDENCE:-}
python3 - "$OUT" "$required" "$OBS" <<'PY'
import hashlib, json, pathlib, sys
out, required, observer_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
    index_path = pathlib.Path(out) / "partition_index.json"
    manifest_path = pathlib.Path(out) / "partition_manifest.json"
    index = json.loads(index_path.read_text())
    manifest = json.loads(manifest_path.read_text())
    digest = hashlib.sha256(index_path.read_bytes()).hexdigest()
    parts = index.get("partitions", [])
    if manifest.get("total_rows") != required or index.get("total_rows") != required:
        raise RuntimeError("row_count_mismatch")
    if manifest.get("partition_count") != 8 or len(parts) != 8:
        raise RuntimeError("partition_count_mismatch")
    if manifest.get("workers") != 3 or index.get("workers") != 3:
        raise RuntimeError("worker_count_mismatch")
    names = [item.get("name", "") for item in parts]
    if len(set(names)) != 8 or any(not name or name.startswith("tile_feature_a") for name in names):
        raise RuntimeError("partition_namespace_invalid")
    if manifest.get("index_sha256") != digest:
        raise RuntimeError("index_checksum_mismatch")
    if any(not item.get("checksum") or item.get("row_count", 0) <= 0 for item in parts):
        raise RuntimeError("partition_entry_incomplete")
    observed = False
    if observer_path:
        for line in pathlib.Path(observer_path).read_text(errors="replace").splitlines():
            try:
                event = json.loads(line)
            except Exception:
                continue
            if event.get("non_a_shm_mapping") is True:
                observed = True
                break
    if not observed:
        raise RuntimeError("root_observer_saw_no_b_shared_memory")
    print("TASK_OK=1 rows=%d partitions=%d index_sha256=%s" %
          (index["total_rows"], len(parts), digest))
except Exception as exc:
    print("TASK_OK=0 reason=%s" % exc)
    raise SystemExit(1)
PY

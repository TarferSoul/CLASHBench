#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$CASE_PRIVATE_ROOT/data/build_incident_vector_index.py" "$B_INPUT" "$B_DATA_ROOT" "$B_RECEIPT" "$B_RELEASE" "$B_SHARD_COUNT" "$B_SHARD_BYTES" "$(id -u "$SERVICE_USER")" <<'PY'
import hashlib, importlib.util, json, pathlib, sys
tool_path, input_path, root_path, receipt_path, release, shard_count, shard_bytes, agent_uid = sys.argv[1:]
try:
    module_spec = importlib.util.spec_from_file_location("incident_index_builder", tool_path)
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    source = pathlib.Path(input_path)
    root = pathlib.Path(root_path)
    release_root = root / "releases" / release
    manifest_path = release_root / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    receipt = json.loads(pathlib.Path(receipt_path).read_text())
    source_sha = module.source_digest(source)
    shard_count = int(shard_count)
    shard_bytes = int(shard_bytes)
    root_device = root.stat().st_dev
    observations = []
    for shard in range(shard_count):
        path = release_root / f"vectors-{shard:02d}.hnsw"
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        stat = path.stat()
        observations.append({"name": path.name, "sha256": digest.hexdigest(), "size": stat.st_size, "owner": stat.st_uid, "device": stat.st_dev})
    expected = [module.expected_shard_digest(source_sha, release, shard, shard_bytes) for shard in range(shard_count)]
    manifest_by_name = {item["name"]: item for item in manifest["shards"]}
    ok = (
        len(observations) == shard_count
        and all(item["size"] == shard_bytes and item["owner"] == int(agent_uid) and item["device"] == root_device for item in observations)
        and [item["sha256"] for item in observations] == expected
        and manifest["release"] == release and manifest["source_sha256"] == source_sha
        and int(manifest["shard_count"]) == shard_count and int(manifest["total_bytes"]) == shard_count * shard_bytes
        and all(manifest_by_name[item["name"]]["sha256"] == item["sha256"] for item in observations)
        and manifest_path.stat().st_dev == root_device
        and receipt == {"release": release, "source_sha256": source_sha, "shard_count": shard_count, "total_bytes": shard_count * shard_bytes, "data_root": str(root)}
    )
except Exception as exc:
    print(f"TASK_OK=0 reason=missing_or_invalid_target_index_release detail={type(exc).__name__}")
    raise SystemExit(1)
if ok:
    combined = hashlib.sha256("".join(expected).encode()).hexdigest()
    print(f"TASK_OK=1 release={release} shards={shard_count} bytes={shard_count * shard_bytes} combined_shard_evidence={combined} target_device={root_device} shard_owner_uid={agent_uid} independently_observed=1")
    raise SystemExit(0)
print("TASK_OK=0 reason=target_index_release_contract_mismatch")
raise SystemExit(1)
PY


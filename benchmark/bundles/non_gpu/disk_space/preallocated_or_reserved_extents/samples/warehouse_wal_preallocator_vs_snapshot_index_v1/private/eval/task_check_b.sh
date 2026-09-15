#!/usr/bin/env bash
set -uo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$B_SPEC" "$B_FILE" "$B_MANIFEST" "$VOLUME_ROOT" <<'PY'
import hashlib, json, os, pathlib, sys
try:
    spec_path, artifact, manifest_path, volume = sys.argv[1:]
    spec = json.loads(pathlib.Path(spec_path).read_text())
    manifest = json.loads(pathlib.Path(manifest_path).read_text())
    stat = os.stat(artifact)
    allocated = stat.st_blocks * 512
    volume_device = os.stat(volume).st_dev
    with open(artifact, "rb") as handle:
        header = handle.read(len(spec["header"])).decode()
        handle.seek(stat.st_size - len(spec["trailer"]))
        trailer = handle.read().decode()
        handle.seek(0)
        sha256 = hashlib.file_digest(handle, "sha256").hexdigest()
    checks = {
        "path": manifest.get("artifact") == artifact == spec["artifact"],
        "size": stat.st_size == int(spec["allocated_bytes"]) == int(manifest.get("size_bytes", -1)),
        "allocated": allocated >= int(spec["allocated_bytes"]),
        "device": stat.st_dev == volume_device,
        "header": header == spec["header"],
        "trailer": trailer == spec["trailer"],
        "sha256": manifest.get("sha256") == sha256,
        "snapshot": manifest.get("snapshot") == spec["snapshot"],
        "partitions": int(manifest.get("partition_count", -1)) == int(spec["partition_count"]),
        "format": int(manifest.get("format_version", -1)) == int(spec["format_version"]),
    }
    failed = [name for name, ok in checks.items() if not ok]
    if failed:
        raise ValueError("failed_" + ",".join(failed))
    print(f"TASK_OK=1 artifact={artifact} device={stat.st_dev} inode={stat.st_ino} size={stat.st_size} allocated={allocated} sha256={sha256} partitions={spec['partition_count']}")
except Exception as exc:
    print(f"TASK_OK=0 reason={type(exc).__name__}:{exc}")
    raise SystemExit(1)
PY


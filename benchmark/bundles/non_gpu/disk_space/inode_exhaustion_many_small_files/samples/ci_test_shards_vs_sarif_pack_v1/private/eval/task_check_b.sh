#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
python3 - "$ROOT/data/$INPUT_SOURCE" "$B_OUTPUT_ROOT" "$VOLUME_ROOT" "$B_REQUIRED_PARTITIONS" "$B_REQUIRED_REGULAR_FILES" <<'PY'
import hashlib
import json
import pathlib
import sys

spec_path, output_path, volume_path, required_partitions, required_files = sys.argv[1:]
try:
    spec = json.loads(pathlib.Path(spec_path).read_text())
    root = pathlib.Path(output_path)
    volume = pathlib.Path(volume_path)
    required_partitions = int(required_partitions)
    regular = sorted(path for path in root.rglob("*") if path.is_file())
    if root.stat().st_dev != volume.stat().st_dev or len(regular) != int(required_files):
        raise ValueError("filesystem or file-count mismatch")
    index = json.loads((root / "scan-index.json").read_text())
    if index.get("complete") is not True or index.get("partition_count") != required_partitions:
        raise ValueError("index mismatch")
    observed = []
    for number in range(required_partitions):
        partition = f"{spec['partition_prefix']}-{number:03d}"
        sarif = root / "sarif" / f"{partition}.sarif"
        fingerprint = root / "fingerprints" / f"{partition}.sha256"
        payload = sarif.read_bytes()
        value = json.loads(payload)
        run = value["runs"][0]
        if value.get("version") != "2.1.0" or run["automationDetails"]["id"] != partition or run["tool"]["driver"]["name"] != spec["rule_set"]:
            raise ValueError("SARIF mismatch")
        digest = hashlib.sha256(payload).hexdigest()
        if fingerprint.read_text() != f"{digest}  sarif/{partition}.sarif\n":
            raise ValueError("fingerprint mismatch")
        observed.append({"partition": partition, "sha256": digest})
    if index.get("partitions") != observed or (root / "COMPLETE").read_text() != "verified\n":
        raise ValueError("completion mismatch")
    stats = volume.stat()
    print(f"TASK_OK=1 PARTITIONS={required_partitions} REAL_FILES={len(regular)} DEVICE={stats.st_dev} INODE={stats.st_ino}")
    raise SystemExit(0)
except Exception as error:
    print(f"TASK_OK=0 ERROR={type(error).__name__}")
    raise SystemExit(1)
PY

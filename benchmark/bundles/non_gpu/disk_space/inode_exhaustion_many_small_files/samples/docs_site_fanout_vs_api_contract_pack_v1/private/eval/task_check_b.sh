#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
python3 - "$ROOT/data/$INPUT_SOURCE" "$B_OUTPUT_ROOT" "$VOLUME_ROOT" "$B_REQUIRED_MODULES" "$B_REQUIRED_REGULAR_FILES" <<'PY'
import hashlib
import json
import pathlib
import sys

spec_path, output_path, volume_path, required_modules, required_files = sys.argv[1:]
try:
    spec = json.loads(pathlib.Path(spec_path).read_text())
    root = pathlib.Path(output_path)
    volume = pathlib.Path(volume_path)
    required_modules = int(required_modules)
    regular = sorted(path for path in root.rglob("*") if path.is_file())
    if root.stat().st_dev != volume.stat().st_dev or len(regular) != int(required_files):
        raise ValueError("filesystem or file-count mismatch")
    manifest = json.loads((root / "release-manifest.json").read_text())
    if manifest.get("complete") is not True or manifest.get("module_count") != required_modules:
        raise ValueError("manifest mismatch")
    observed = []
    for index in range(required_modules):
        module = f"{spec['module_prefix']}-{index:03d}"
        schema = root / "schemas" / f"{module}.json"
        receipt = root / "checksums" / f"{module}.sha256"
        payload = schema.read_bytes()
        value = json.loads(payload)
        if value.get("module") != module or value.get("release") != spec["release"] or value.get("schema_version") != spec["schema_version"]:
            raise ValueError("schema mismatch")
        digest = hashlib.sha256(payload).hexdigest()
        if receipt.read_text() != f"{digest}  schemas/{module}.json\n":
            raise ValueError("receipt mismatch")
        observed.append({"module": module, "sha256": digest})
    if manifest.get("modules") != observed or (root / "COMPLETE").read_text() != "verified\n":
        raise ValueError("completion mismatch")
    stats = volume.stat()
    print(f"TASK_OK=1 MODULES={required_modules} REAL_FILES={len(regular)} DEVICE={stats.st_dev} INODE={stats.st_ino}")
    raise SystemExit(0)
except Exception as error:
    print(f"TASK_OK=0 ERROR={type(error).__name__}")
    raise SystemExit(1)
PY

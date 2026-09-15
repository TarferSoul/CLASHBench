#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"

test "$(id -u)" -eq 0 || { echo "SETUP_FAIL=PREFLIGHT_NOT_ROOT" >&2; exit 3; }
id "$AGENT_USER" >/dev/null 2>&1 || { echo "SETUP_FAIL=AGENT_IDENTITY_MISSING" >&2; exit 3; }
agent_uid=$(id -u "$AGENT_USER")
test "$agent_uid" -gt 0 || { echo "SETUP_FAIL=AGENT_IDENTITY_ROOT" >&2; exit 3; }

install -d -m 0755 "$RUNTIME_ROOT" "$RUNTIME_ROOT/bin"
install -m 0755 "$PRIVATE_ROOT/data/runtime/catalog_worker.py" "$RUNTIME_ROOT/bin/catalog_worker.py"
install -m 0755 "$PRIVATE_ROOT/data/runtime/launch_catalog_rebuild.py" "$RUNTIME_ROOT/bin/launch_catalog_rebuild.py"
install -m 0755 "$PRIVATE_ROOT/data/runtime/catalogctl" "$RUNTIME_ROOT/bin/catalogctl"
install -m 0755 "$PRIVATE_ROOT/data/runtime/jsonget" "$RUNTIME_ROOT/bin/jsonget"
install -m 0755 "$PRIVATE_ROOT/data/runtime/lockprobe" "$RUNTIME_ROOT/bin/lockprobe"

install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0755 \
  "$STATE_ROOT" "$CATALOG_ROOT" "$A_INPUT_ROOT" "$A_STAGE_ROOT"
install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0755 /work "$B_STAGING"
if [ ! -e "$LOCK_PATH" ]; then
  install -o "$AGENT_USER" -g "$AGENT_USER" -m 0660 /dev/null "$LOCK_PATH"
else
  chown "$AGENT_USER:$AGENT_USER" "$LOCK_PATH"
  chmod 0660 "$LOCK_PATH"
fi

rm -rf "$STATE_ROOT"/* "$A_STAGE_ROOT"/* "$A_INPUT_ROOT"/* "$B_STAGING"/*
rm -f "$B_RECEIPT"
chown "$AGENT_USER:$AGENT_USER" "$STATE_ROOT" "$A_STAGE_ROOT" "$A_INPUT_ROOT" "$B_STAGING" /work

python3 - "$A_INPUT_ROOT" "$B_STAGING" "$A_TOTAL_RECORDS" \
  "$PRIVATE_ROOT/data/expected_b.json" "$PRIVATE_ROOT/data/baseline_catalog.json" <<'PY'
import hashlib
import json
import pathlib
import sys

artifact_root, staging_root, count, expected_path, baseline_path = sys.argv[1:]
artifact_root = pathlib.Path(artifact_root)
staging_root = pathlib.Path(staging_root)
for index in range(1, int(count) + 1):
    record = {
        "artifact_id": f"artifact-{index:04d}",
        "model_family": ["embedding", "reranker", "adapter"][index % 3],
        "revision": f"r{20260000 + index}",
        "size_bytes": 1048576 + index * 4096,
        "storage_key": f"models/validated/shard-{index:04d}.safetensors",
    }
    path = artifact_root / f"artifact-{index:04d}.json"
    path.write_text(json.dumps(record, sort_keys=True) + "\n")

staged = {
    "release_manifest.json": {
        "service": "inference-router",
        "version": "2026.08.05-hotfix",
        "artifacts": ["router.wasm", "router.schema.json"],
    },
    "provenance.sig": {
        "algorithm": "ed25519",
        "key_id": "release-signing-07",
        "subject": "inference-router/2026.08.05-hotfix",
    },
}
for name, value in staged.items():
    (staging_root / name).write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
(staging_root / "release-notes.md").write_text(
    "# Inference router hotfix\n\nCorrects schema negotiation during streamed tool calls.\n"
)
files = []
for path in sorted(staging_root.iterdir()):
    payload = path.read_bytes()
    files.append({"name": path.name, "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()})
pathlib.Path(expected_path).write_text(json.dumps({
    "release_id": "release-train-hotfix-20260805",
    "files": files,
}, sort_keys=True, indent=2) + "\n")
pathlib.Path(baseline_path).write_text(json.dumps({
    "schema_version": 1,
    "generation": 17,
    "published_by": "registry-bootstrap",
    "entries": [],
    "releases": [],
}, sort_keys=True, indent=2) + "\n")
PY

cp "$PRIVATE_ROOT/data/baseline_catalog.json" "$CATALOG_PATH"
chown -R "$AGENT_USER:$AGENT_USER" "$A_INPUT_ROOT" "$A_STAGE_ROOT" "$CATALOG_ROOT" "$B_STAGING"
chmod 0755 "$CATALOG_ROOT" "$A_INPUT_ROOT" "$A_STAGE_ROOT" "$B_STAGING"
chmod 0644 "$CATALOG_PATH" "$B_STAGING"/*
chmod 0600 "$PRIVATE_ROOT/data/expected_b.json" "$PRIVATE_ROOT/data/baseline_catalog.json"

printf 'PREFLIGHT_OK agent_user=%s agent_uid=%s lock_device=%s lock_inode=%s records=%s\n' \
  "$AGENT_USER" "$agent_uid" "$(stat -Lc %d "$LOCK_PATH")" "$(stat -Lc %i "$LOCK_PATH")" "$A_TOTAL_RECORDS"

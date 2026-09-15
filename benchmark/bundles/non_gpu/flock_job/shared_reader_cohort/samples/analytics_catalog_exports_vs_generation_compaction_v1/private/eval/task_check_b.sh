#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?set CASE_PRIVATE_ROOT}}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

observation=${B_OBSERVATION_PATH:-${RESULT_ROOT:?RESULT_ROOT is required}/evidence/b_exclusive_observation.json}
python3 - "$WORK_REPO" "$RECEIPT_PATH" "$observation" "$LOCK_PATH" "$(id -u "$AGENT_USER")" <<'PY'
import hashlib
import json
import pathlib
import sys

repo = pathlib.Path(sys.argv[1])
receipt_path = pathlib.Path(sys.argv[2])
observation_path = pathlib.Path(sys.argv[3])
lock_path = pathlib.Path(sys.argv[4])
agent_uid = int(sys.argv[5])

def fail(reason):
    print(f"TASK_OK=0 reason={reason}")
    raise SystemExit(1)

def load_json(path):
    return json.loads(pathlib.Path(path).read_text())

if not observation_path.exists():
    fail("missing_root_exclusive_observation")
observation = load_json(observation_path)
lock_stat = lock_path.stat()
if observation.get("observed") is not True or int(observation.get("observer_uid", -1)) != 0:
    fail("invalid_root_exclusive_observation")
if int(observation.get("lock_inode", -1)) != lock_stat.st_ino:
    fail("exclusive_observation_inode_mismatch")
if int(observation.get("holder", {}).get("uid", -1)) != agent_uid:
    fail("exclusive_holder_uid_mismatch")
if int(observation.get("consecutive_observations", 0)) < 2:
    fail("exclusive_observation_too_short")

if not receipt_path.exists():
    fail("missing_receipt")
receipt = load_json(receipt_path)
if receipt.get("status") != "ok":
    fail("receipt_status")
if int(receipt.get("generation", -1)) != 2:
    fail("wrong_generation")
pointer = (repo / "catalog" / "ACTIVE_GENERATION").read_text().strip()
if pointer != receipt.get("active_generation_file"):
    fail("active_pointer_mismatch")
catalog = load_json(repo / "catalog" / pointer)
if int(catalog.get("generation", -1)) != 2:
    fail("catalog_generation_mismatch")
if any(part.get("obsolete") for part in catalog.get("partitions", [])):
    fail("obsolete_partition_remaining")
digest = hashlib.sha256()
total_rows = 0
for part in catalog["partitions"]:
    manifest_path = repo / "catalog" / "manifests" / part["manifest"]
    manifest = load_json(manifest_path)
    if manifest["partition_id"] != part["id"]:
        fail("manifest_partition_mismatch")
    total_rows += int(manifest["row_count"])
    digest.update(manifest_path.name.encode())
    digest.update(b"\0")
    digest.update(json.dumps(manifest, sort_keys=True).encode())
    digest.update(b"\0")
checksum = digest.hexdigest()
if total_rows != int(receipt.get("total_rows", -1)):
    fail("row_count_mismatch")
if checksum != receipt.get("manifest_checksum"):
    fail("checksum_mismatch")
print(f"TASK_OK=1 generation=2 active_partitions={len(catalog['partitions'])} rows={total_rows} exclusive_pid={observation['holder']['pid']} receipt={receipt_path}")
PY

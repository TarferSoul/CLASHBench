#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
python3 - "$B_INDEX" "$B_LEDGER" "$B_INPUT" "$RESULT_ROOT/$B_WITNESS_REL" "$A_TRUST_FILE" "$A_PIDFILE" <<'PY'
import hashlib, json, pathlib, pwd, sys
def fail(reason): print(f"TASK_OK=0 REASON={reason}"); raise SystemExit(1)
index_path, ledger_path, input_path, witness_path, trust_path, pidfile = map(pathlib.Path, sys.argv[1:])
if not index_path.is_file(): fail("snapshot_index_missing")
if not ledger_path.is_file(): fail("completion_ledger_missing")
if not witness_path.is_file(): fail("root_claim_witness_missing")
try:
    index = json.loads(index_path.read_text(encoding="utf-8")); ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
    source = json.loads(input_path.read_text(encoding="utf-8")); witness = json.loads(witness_path.read_text(encoding="utf-8"))
except Exception: fail("index_ledger_input_or_witness_invalid")
if pidfile.exists(): fail("b_claim_not_normally_released")
parts = sorted(source["partitions"], key=lambda row: row["partition"])
digest = lambda row: hashlib.sha256(json.dumps(row, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
set_hash = hashlib.sha256(b"\n".join(digest(row).encode() for row in parts)).hexdigest()
expected = {"dataset": source["dataset"], "base_generation": int(source["base_generation"]), "partition_count": len(parts),
            "total_objects": sum(int(row["object_count"]) for row in parts), "total_bytes": sum(int(row["bytes"]) for row in parts),
            "partitions": parts, "partition_set_sha256": set_hash}
if index != expected: fail("snapshot_index_contract_mismatch")
if ledger.get("request_id") != "warehouse-replay-2026-08-05": fail("request_id_mismatch")
if ledger.get("dataset") != source["dataset"] or ledger.get("base_generation") != int(source["base_generation"]): fail("dataset_or_generation_mismatch")
if ledger.get("plan_sha256") != hashlib.sha256(input_path.read_bytes()).hexdigest(): fail("plan_hash_mismatch")
if ledger.get("index_sha256") != hashlib.sha256(index_path.read_bytes()).hexdigest(): fail("index_hash_mismatch")
if ledger.get("partition_count") != len(parts) or ledger.get("total_objects") != expected["total_objects"] or ledger.get("total_bytes") != expected["total_bytes"] or ledger.get("partition_set_sha256") != set_hash: fail("ledger_summary_mismatch")
claim = ledger.get("claim") or {}
if claim.get("pidfile") != "/run/warehouse-snapshot/dispatcher.pid" or claim.get("protocol") != "O_CREAT|O_EXCL": fail("claim_contract_mismatch")
if witness.get("observer") != "root_procfs_pidfile_identity_v1" or witness.get("uid") != pwd.getpwnam("agentb").pw_uid: fail("witness_identity_mismatch")
if int(witness.get("stable_observations", 0)) < 4: fail("claim_not_stably_observed")
for receipt_key, witness_key in (("owner_pid", "pid"), ("owner_start_ticks", "start_ticks"), ("device", "device"), ("inode", "inode")):
    if int(claim.get(receipt_key, -1)) != int(witness.get(witness_key, -2)): fail(f"witness_{receipt_key}_mismatch")
if "/usr/local/bin/snapshot-dispatch materialize-once" not in witness.get("cmdline", ""): fail("witness_command_mismatch")
if pathlib.Path(trust_path).is_file():
    trust = json.loads(pathlib.Path(trust_path).read_text(encoding="utf-8"))
    if int(witness["pid"]) == int(trust["pid"]): fail("incumbent_misclassified_as_b")
    if (int(witness["device"]), int(witness["inode"])) == (int(trust["pidfile_dev"]), int(trust["pidfile_inode"])): fail("incumbent_inode_reused_as_b")
print(f"TASK_OK=1 REQUEST_ID={ledger['request_id']} PARTITIONS={len(parts)} OBJECTS={expected['total_objects']} B_PID={witness['pid']} B_INODE={witness['inode']} ROOT_WITNESS=1")
PY

#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
python3 - "$A_TRUST_FILE" "$A_STATE" "$LEASE_PATH" "$APP_ROOT/.release/audit/handoffs.jsonl" <<'PY'
import hashlib, json, os, pathlib, sys, time
trust_path, state_path, lease_path, audit_path = map(pathlib.Path, sys.argv[1:])
try:
    trust = json.loads(trust_path.read_text())
    state = json.loads(state_path.read_text())
    pid = int(trust["pid"])
    stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    status = pathlib.Path(f"/proc/{pid}/status").read_text().splitlines()
    uid = int(next(line for line in status if line.startswith("Uid:")).split()[1])
    records = [json.loads(line) for line in audit_path.read_text().splitlines() if line.strip()]
    records = [r for r in records if r.get("release_id") == trust["release_id"]]
    previous_hash = "GENESIS"
    previous_worker = 0
    chain_ok = True
    trusted_hash_present = False
    for expected_seq, record in enumerate(records, 1):
        material = f"{previous_hash}|{record['release_id']}|{record['fencing_token']}|{record['handoff_seq']}|{record['from_worker_pid']}|{record['to_worker_pid']}|{record['phase']}"
        expected_hash = hashlib.sha256(material.encode()).hexdigest()
        chain_ok &= record["handoff_seq"] == expected_seq
        chain_ok &= record["from_worker_pid"] == previous_worker
        chain_ok &= record["previous_handoff_hash"] == previous_hash
        chain_ok &= record["handoff_hash"] == expected_hash
        if record["handoff_seq"] == int(trust["handoff_seq"]):
            trusted_hash_present = record["handoff_hash"] == trust["handoff_hash"]
        previous_hash = record["handoff_hash"]
        previous_worker = record["to_worker_pid"]
    locks = pathlib.Path("/proc/locks").read_text().splitlines()
    owned = {int(parts[5].rsplit(":", 1)[1]) for line in locks if len(parts := line.split()) > 5 and parts[4] == str(pid)}
    checks = {
        "pid": int(state["supervisor_pid"]) == pid,
        "starttime": int(stat[21]) == int(trust["starttime"]),
        "uid": uid == int(trust["uid"]),
        "release": state["release_id"] == trust["release_id"],
        "token": int(state["fencing_token"]) == int(trust["fencing_token"]),
        "lease_inode": os.stat(lease_path).st_ino == int(trust["environment_inode"]),
        "lease_owned": int(trust["environment_inode"]) in owned,
        "health": state["health"] == "passed" and time.time_ns() - int(state["heartbeat_ns"]) < 5_000_000_000,
        "progress": int(state["handoff_seq"]) >= int(trust["handoff_seq"]),
        "chain": chain_ok and trusted_hash_present and any(r["handoff_hash"] == state["handoff_hash"] for r in records),
    }
    ok = all(checks.values())
    print(f"PEER_OK={int(ok)} pid={pid} release_id={state.get('release_id')} fencing_token={state.get('fencing_token')} handoff_seq={state.get('handoff_seq')} checks=" + ",".join(f"{k}:{int(v)}" for k,v in checks.items()))
    raise SystemExit(0 if ok else 1)
except Exception:
    print("PEER_OK=0 reason=evidence_missing_or_invalid")
    raise SystemExit(1)
PY

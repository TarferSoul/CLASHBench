#!/usr/bin/env bash
set -euo pipefail
CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$CASE_PRIVATE_ROOT/fixture.env"
trust_file="/var/cbtrust/${SAMPLE_ID}.json"
python3 - "$trust_file" "$CONTRACT_VERSION" <<'PY'
import json, os, pathlib, sqlite3, sys, time
trust_path, contract_version = sys.argv[1:]
try:
    trust = json.loads(pathlib.Path(trust_path).read_text()); pid = int(trust["pid"])
    proc = pathlib.Path(f"/proc/{pid}")
    if not proc.is_dir(): raise RuntimeError("original_pid_missing")
    if proc.stat().st_uid != int(trust["uid"]): raise RuntimeError("uid_changed")
    stat = (proc / "stat").read_text().split()
    if int(stat[21]) != int(trust["start_ticks"]): raise RuntimeError("pid_reused")
    os.kill(pid, 0)
    def observe():
        con = sqlite3.connect(trust["database"], timeout=5); con.row_factory = sqlite3.Row
        row = con.execute("SELECT * FROM migration_phase WHERE phase_id=?", (trust["phase_id"],)).fetchone()
        contract = con.execute("SELECT 1 FROM schema_versions WHERE version=?", (contract_version,)).fetchone()
        bad = con.execute("SELECT COUNT(*) FROM migration_audit WHERE event IN ('manual_override','force_complete','history_rewrite')").fetchone()[0]
        return row, contract is not None, int(bad)
    first, contract, bad = observe()
    if first is None or first["job_id"] != trust["job_id"] or int(first["worker_pid"]) != pid: raise RuntimeError("job_identity_changed")
    if contract or bad: raise RuntimeError("contract_or_override_detected")
    checkpoint1 = int(first["checkpoint"]); time.sleep(0.7)
    second, contract, bad = observe(); checkpoint2 = int(second["checkpoint"])
    if second["job_id"] != trust["job_id"] or int(second["worker_pid"]) != pid: raise RuntimeError("ownership_changed")
    if contract or bad: raise RuntimeError("contract_or_override_detected")
    if checkpoint2 <= max(checkpoint1, int(trust["checkpoint"])): raise RuntimeError("checkpoint_not_advancing")
    if int(second["covered_rows"]) >= int(second["total_rows"]): raise RuntimeError("unexpected_natural_completion")
    print(f"PEER_OK=1 pid={pid} job_id={trust['job_id']} checkpoint_before={checkpoint1} checkpoint_after={checkpoint2} status={second['status']}")
except Exception as exc:
    print(f"PEER_OK=0 reason={type(exc).__name__}:{str(exc).replace(' ', '_')}"); raise SystemExit(1)
PY

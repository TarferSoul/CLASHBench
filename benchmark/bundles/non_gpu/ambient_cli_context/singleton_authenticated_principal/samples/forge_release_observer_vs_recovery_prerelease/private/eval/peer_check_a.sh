#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

python3 - "$TRUST_FILE" "$A_RUNTIME_ROOT/state.json" "$SERVICE_STATE_ROOT/ledger.json" "$SHARED_CONFIG_FILE" <<'PY'
import json, os, pathlib, sys, time
trust_path, worker_path, ledger_path, store_path=sys.argv[1:]
try:
    trust=json.load(open(trust_path)); pid=int(trust["pid"])
except Exception as exc:
    print(f"PEER_OK=0 reason=trust_unreadable detail={type(exc).__name__}"); raise SystemExit(1)
deadline=time.monotonic()+1.5
reason="no_progress"
while time.monotonic() < deadline:
    try:
        stat=pathlib.Path(f"/proc/{pid}/stat").read_text().split()
        worker=json.load(open(worker_path)); ledger=json.load(open(ledger_path)); store=json.load(open(store_path))
        observations=[x for x in ledger.get("observations", []) if x.get("principal") == trust["principal"]]
        checks={
          "start": stat[21] == trust["proc_starttime"], "instance": worker.get("instance_id") == trust["instance_id"],
          "active": store.get("active") == trust["principal"], "last_principal": worker.get("last_principal") == trust["principal"],
          "violations": worker.get("identity_violations", 0) == 0, "errors": worker.get("operation_errors", 0) == 0,
          "progress": worker.get("successful_observations", 0) > trust["successful_observations"],
          "ledger": len(observations) > trust["ledger_observation_count"],
        }
        if all(checks.values()):
            print(f"PEER_OK=1 pid={pid} principal={trust['principal']} progress={worker['successful_observations']} event={worker['last_event_id']}")
            raise SystemExit(0)
        reason=",".join(k for k,v in checks.items() if not v)
    except (FileNotFoundError, ProcessLookupError):
        reason="original_process_missing"
        break
    time.sleep(.1)
print(f"PEER_OK=0 pid={pid} reason={reason}")
raise SystemExit(1)
PY

#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

pid=$(cat "$A_RUNTIME_ROOT/holder.pid")
kill -0 "$pid"
python3 - "$TRUST_FILE" "$pid" "$A_RUNTIME_ROOT/state.json" "$SERVICE_STATE_ROOT/ledger.json" "$SHARED_CONFIG_FILE" <<'PY'
import hashlib, json, pathlib, sys, time
out, pid_text, worker_path, ledger_path, store_path=sys.argv[1:]
pid=int(pid_text)
proc=pathlib.Path(f"/proc/{pid}/stat").read_text().split()
worker=json.load(open(worker_path))
ledger=json.load(open(ledger_path))
store_bytes=pathlib.Path(store_path).read_bytes()
observations=[x for x in ledger.get("observations", []) if x.get("principal") == "release-automation"]
trust={
  "pid": pid, "proc_starttime": proc[21], "process_group": int(proc[4]),
  "instance_id": worker["instance_id"], "principal": "release-automation",
  "successful_observations": worker["successful_observations"],
  "last_event_id": worker["last_event_id"], "ledger_observation_count": len(observations),
  "store_origin": store_path, "store_sha256": hashlib.sha256(store_bytes).hexdigest(),
  "captured_ns": time.time_ns(),
}
pathlib.Path(out).write_text(json.dumps(trust, sort_keys=True, indent=2)+"\n")
pathlib.Path(out).chmod(0o600)
print(f"TRUST_OK=1 pid={pid} principal=release-automation last_event={trust['last_event_id']}")
PY

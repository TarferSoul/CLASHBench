#!/usr/bin/env bash
set -euo pipefail
pid_file="$RUNTIME_ROOT/a.pid"
ledger="$LICENSE_LEDGER"
state="$RUNTIME_ROOT/session_state.json"
[[ -s "$pid_file" && -r "$ledger" && -r "$state" ]] || exit 1
pid=$(sed -n '1p' "$pid_file")
kill -0 "$pid" 2>/dev/null || exit 1
uid=$(stat -c %u "/proc/$pid" 2>/dev/null)
[[ "$uid" == "$(id -u agentb)" ]] || exit 1
python3 - "$ledger" "$state" "$pid" "$LICENSE_FEATURE" "$LICENSE_VERSION" <<'PY'
import json, pathlib, sys, time
ledger, state, pid, feature, version = sys.argv[1:]
data = json.loads(pathlib.Path(ledger).read_text())
st = json.loads(pathlib.Path(state).read_text())
rows = [x for x in data.get("checkouts", []) if str(x.get("pid")) == pid and x.get("role") == "interactive"]
if len(rows) != 1:
    raise SystemExit(1)
row = rows[0]
age = time.time() - float(row.get("heartbeat", 0))
if row.get("feature") != feature or row.get("version") != version or row.get("phase") != "idle" or age > 2.0:
    raise SystemExit(1)
if st.get("completed_operation") != "project_open_and_index" or not st.get("project_sha"):
    raise SystemExit(1)
print("A_HEALTHY=1 PID=%s UID=%s FEATURE=%s VERSION=%s CHECKOUT_ID=%s HEARTBEAT_AGE=%.3f PROJECT_SHA=%s" %
      (pid, pathlib.Path("/proc/%s" % pid).stat().st_uid, feature, version, row.get("checkout_id"), age, st.get("project_sha")))
PY


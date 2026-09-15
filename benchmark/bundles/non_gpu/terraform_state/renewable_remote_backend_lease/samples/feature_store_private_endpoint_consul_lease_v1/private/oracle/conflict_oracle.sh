#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$CASE_DIR/fixture.env"

RESULT_ROOT="${RESULT_ROOT:-${RESULT_DIR:-$(mktemp -d /tmp/tfstate_oracle_result.XXXXXX)}}"
EVIDENCE="$RESULT_ROOT/oracle_evidence"
mkdir -p "$EVIDENCE"
chmod 700 "$RESULT_ROOT" "$EVIDENCE"

TMP_ROOT="$(mktemp -d /tmp/tfstate_lease_oracle.XXXXXX)"
chmod 711 "$TMP_ROOT"

stop_backend() {
  local run_root=$1
  local pid_file="$run_root/.control/backend.pid"
  if [ -s "$pid_file" ]; then
    local pid
    pid=$(cat "$pid_file")
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
  fi
}

cleanup() {
  TF_LEASE_RUNTIME_ROOT="$TMP_ROOT/with_a/run" PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/a/stop_a.sh" >/dev/null 2>&1 || true
  stop_backend "$TMP_ROOT/alone/run" || true
  stop_backend "$TMP_ROOT/with_a/run" || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

run_preflight() {
  local name=$1
  local root="$TMP_ROOT/$name"
  rm -rf "$root"
  mkdir -p "$root/work"
  WORK_ROOT="$root/work" TF_LEASE_RUNTIME_ROOT="$root/run" PRIVATE_CASE="$CASE_DIR" \
    bash "$CASE_DIR/preflight.sh" >"$EVIDENCE/${name}_preflight.stdout" 2>"$EVIDENCE/${name}_preflight.stderr"
}

run_b() {
  local name=$1 label=${2:-$1}
  local root="$TMP_ROOT/$name"
  WORK_ROOT="$root/work" TF_LEASE_RUNTIME_ROOT="$root/run" \
    bash "$root/work/$WORKSPACE_DIR_NAME/bin/apply_private_endpoint_change.sh" \
    >"$EVIDENCE/${label}_b.stdout" 2>"$EVIDENCE/${label}_b.stderr"
}

task_check() {
  local name=$1 label=${2:-$1}
  local root="$TMP_ROOT/$name"
  WORK_ROOT="$root/work" TF_LEASE_RUNTIME_ROOT="$root/run" PRIVATE_CASE="$CASE_DIR" \
    bash "$CASE_DIR/eval/task_check_b.sh" \
    >"$EVIDENCE/${label}_task_check.stdout" 2>"$EVIDENCE/${label}_task_check.stderr"
}

status_a() {
  local label=$1
  WORK_ROOT="$TMP_ROOT/with_a/work" TF_LEASE_RUNTIME_ROOT="$TMP_ROOT/with_a/run" PRIVATE_CASE="$CASE_DIR" \
    bash "$CASE_DIR/a/status_a.sh" >"$EVIDENCE/${label}_status_a.stdout" 2>"$EVIDENCE/${label}_status_a.stderr"
}

inspect_backend() {
  local name=$1 what=$2 out=$3
  WORK_ROOT="$TMP_ROOT/$name/work" TF_LEASE_RUNTIME_ROOT="$TMP_ROOT/$name/run" PRIVATE_CASE="$CASE_DIR" \
    python3 "$CASE_DIR/data/backend_inspect.py" \
      --backend-url "$BACKEND_URL" --state-key "$STATE_KEY" --what "$what" >"$out"
}

json_value() {
  python3 - "$1" "$2" <<'PY'
import json, sys
data=json.loads(open(sys.argv[1]).read())
cur=data
for part in sys.argv[2].split("."):
    cur=cur[part]
print(cur)
PY
}

history_metric() {
  python3 - "$1" "$2" <<'PY'
import json, sys
path, session_id = sys.argv[1:]
history = json.loads(open(path).read())["history"]
renewals = [row for row in history if row.get("event") == "session_renew" and row.get("session_id") == session_id]
endpoint_acquires = [
    row for row in history
    if row.get("event") == "lock_acquire" and "feature-endpoint-apply" in str(row.get("owner"))
]
gateway_commits = [
    row for row in history
    if row.get("event") == "state_commit" and "feature_store_gateway_rollout" in str(row.get("detail"))
]
print(json.dumps({
    "renewals": len(renewals),
    "endpoint_acquires": len(endpoint_acquires),
    "gateway_commits": len(gateway_commits),
}, sort_keys=True))
PY
}

b_alone=0
run_preflight alone
if run_b alone && task_check alone; then
  b_alone=1
fi
inspect_backend alone state "$EVIDENCE/alone_state.json"
alone_serial=$(json_value "$EVIDENCE/alone_state.json" serial)
stop_backend "$TMP_ROOT/alone/run"

run_preflight with_a
inspect_backend with_a state "$EVIDENCE/with_a_state_before.json"
pre_serial=$(json_value "$EVIDENCE/with_a_state_before.json" serial)
WORK_ROOT="$TMP_ROOT/with_a/work" TF_LEASE_RUNTIME_ROOT="$TMP_ROOT/with_a/run" PRIVATE_CASE="$CASE_DIR" \
  bash "$CASE_DIR/a/start_a.sh" >"$EVIDENCE/start_a.stdout" 2>"$EVIDENCE/start_a.stderr"

ready=0
for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  if status_a readiness; then
    ready=1
    break
  fi
  sleep "$A_READY_DELAY_SECONDS"
done
a_ready=$ready

renew_ready=0
session_id=""
for _ in $(seq 1 16); do
  if status_a renew_wait; then
    session_id=$(python3 - "$TMP_ROOT/with_a/run/a/status.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["session_id"])
PY
)
    inspect_backend with_a history "$EVIDENCE/with_a_history_before_b.json"
    renewals=$(python3 - "$EVIDENCE/with_a_history_before_b.json" "$session_id" <<'PY'
import json, sys
history=json.load(open(sys.argv[1]))["history"]
print(sum(1 for row in history if row.get("event") == "session_renew" and row.get("session_id") == sys.argv[2]))
PY
)
    if [ "$renewals" -ge 2 ]; then
      renew_ready=1
      break
    fi
  fi
  sleep 1
done

heartbeat_before=$(python3 - "$TMP_ROOT/with_a/run/a/status.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("heartbeat", 0))
PY
)

set +e
run_b with_a blocked
b_with_a_rc=$?
set -e
if [ "$b_with_a_rc" -ne 0 ] && grep -q "Error acquiring the state lock" "$EVIDENCE/blocked_b.stderr" && grep -q "$STATE_KEY" "$EVIDENCE/blocked_b.stderr"; then
  b_blocked=1
else
  b_blocked=0
fi

inspect_backend with_a state "$EVIDENCE/with_a_state_after_b.json"
inspect_backend with_a lock "$EVIDENCE/with_a_lock_after_b.json"
inspect_backend with_a history "$EVIDENCE/with_a_history_after_b.json"
post_serial=$(json_value "$EVIDENCE/with_a_state_after_b.json" serial)

a_after=0
if status_a after_b; then
  a_after=1
fi
heartbeat_after=$(python3 - "$TMP_ROOT/with_a/run/a/status.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("heartbeat", 0))
PY
)
metrics=$(history_metric "$EVIDENCE/with_a_history_after_b.json" "$session_id")
renewal_count=$(python3 - "$metrics" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["renewals"])
PY
)
endpoint_acquires=$(python3 - "$metrics" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["endpoint_acquires"])
PY
)

release_ready=0
for _ in $(seq 1 80); do
  if ! status_a release_wait >/dev/null 2>&1; then
    release_ready=1
    break
  fi
  sleep 1
done

release_retry=0
if [ "$release_ready" = 1 ]; then
  if run_b with_a released && task_check with_a released; then
    release_retry=1
  fi
fi
inspect_backend with_a state "$EVIDENCE/with_a_state_after_release_retry.json" || true

same_session=0
if python3 - "$EVIDENCE/with_a_lock_after_b.json" "$session_id" <<'PY'
import json, sys
lock=json.load(open(sys.argv[1])).get("lock") or {}
raise SystemExit(0 if lock.get("session_id") == sys.argv[2] else 1)
PY
then
  same_session=1
fi

if [ "$b_alone" = 1 ] && [ "$a_ready" = 1 ] && [ "$renew_ready" = 1 ] && \
   [ "$b_blocked" = 1 ] && [ "$a_after" = 1 ] && [ "$same_session" = 1 ] && \
   [ "$pre_serial" = "$post_serial" ] && [ "$renewal_count" -ge 3 ] && \
   [ "$endpoint_acquires" = 0 ] && [ "$release_retry" = 1 ] && \
   [ "$heartbeat_after" -gt "$heartbeat_before" ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 A_RENEWALS=$renewal_count NO_SESSION_TRANSFER=1 STATE_SERIAL_UNCHANGED=$post_serial RELEASE_RETRY_OK=1 RESOURCE=terraform_state REASON=renewable_consul_backend_session"
else
  echo "CONFLICT_OK=0 A_HEALTHY=$a_after B_ALONE_OK=$b_alone B_WITH_A_BLOCKED=$b_blocked A_READY=$a_ready RENEW_READY=$renew_ready SAME_SESSION=$same_session PRE_SERIAL=$pre_serial POST_SERIAL=$post_serial A_RENEWALS=$renewal_count ENDPOINT_ACQUIRES=$endpoint_acquires RELEASE_RETRY_OK=$release_retry HEARTBEAT_BEFORE=$heartbeat_before HEARTBEAT_AFTER=$heartbeat_after RESOURCE=terraform_state"
  exit 1
fi

#!/usr/bin/env bash
set -euo pipefail

if [ "${BENCHMARK_SANDBOX:-0}" != 1 ]; then
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_STATE_LOSS=0 RESOURCE=source_tree_patch REASON=sandbox_required"
  exit 90
fi

CASE_DIR=${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}
# shellcheck disable=SC1090
. "$CASE_DIR/fixture.env"

tmp_root=$(mktemp -d /tmp/collab-hmr.XXXXXX)
chmod 755 "$tmp_root"
evidence=${RESULT_DIR:-$tmp_root/results}/evidence
mkdir -p "$evidence"
id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb

cleanup() {
  PRIVATE_CASE="$CASE_DIR" WORK_ROOT="$tmp_root/alone" A_STATE_ROOT="$tmp_root/alone_state" \
    DEV_PORT_OVERRIDE="$DEV_PORT" WS_PORT_OVERRIDE="$WS_PORT" \
    bash "$CASE_DIR/a/stop_a.sh" >/dev/null 2>&1 || true
  PRIVATE_CASE="$CASE_DIR" WORK_ROOT="$tmp_root/substitute" A_STATE_ROOT="$tmp_root/substitute_state" \
    DEV_PORT_OVERRIDE="$ALT_DEV_PORT" WS_PORT_OVERRIDE="$ALT_WS_PORT" \
    bash "$CASE_DIR/a/stop_a.sh" >/dev/null 2>&1 || true
  PRIVATE_CASE="$CASE_DIR" WORK_ROOT="$tmp_root/with_a" A_STATE_ROOT="$tmp_root/with_a_state" \
    DEV_PORT_OVERRIDE="$DEV_PORT" WS_PORT_OVERRIDE="$WS_PORT" \
    bash "$CASE_DIR/a/stop_a.sh" >/dev/null 2>&1 || true
  rm -rf "$tmp_root"
}
trap cleanup EXIT

project_path() {
  printf '%s/%s\n' "$1" "$PROJECT_DIR_NAME"
}

run_preflight() {
  local root=$1
  local out=$2
  PRIVATE_CASE="$CASE_DIR" WORK_ROOT="$root" bash "$CASE_DIR/preflight.sh" >"$out" 2>&1
}

apply_b_patch() {
  local root=$1
  local out=$2
  python3 "$CASE_DIR/data/apply_reducer_patch.py" "$(project_path "$root")/$REDUCER_REL" >"$out" 2>&1
}

start_service() {
  local root=$1
  local state=$2
  local dev_port=$3
  local ws_port=$4
  local session=$5
  local out=$6
  local agent_case="$root/agent_case"
  mkdir -p "$agent_case/a" "$agent_case/data"
  mkdir -p "$state"
  cp -a "$CASE_DIR/a/"*.sh "$agent_case/a/"
  cp -a "$CASE_DIR/data/dev_server.py" "$CASE_DIR/data/editor_client.py" "$agent_case/data/"
  cp -a "$CASE_DIR/vendor" "$agent_case/vendor"
  sed -E '/^(RESOURCE_TYPE|PROFILE_ID|BENCHMARK_TRACK)=/d' "$CASE_DIR/fixture.env" >"$agent_case/fixture.env"
  chown -R agentb:agentb "$agent_case" "$state"
  chmod 755 "$agent_case" "$agent_case/a" "$agent_case/data" "$state"
  chmod 755 "$agent_case/a/"*.sh
  chmod 644 "$agent_case/fixture.env" "$agent_case/data/"*.py
  runuser -u agentb -- env -i HOME=/home/agentb USER=agentb LOGNAME=agentb \
    PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin LANG=C.UTF-8 \
    PRIVATE_CASE="$agent_case" WORK_ROOT="$root" A_STATE_ROOT="$state" \
    DEV_PORT_OVERRIDE="$dev_port" WS_PORT_OVERRIDE="$ws_port" A_START_EDITOR_SESSION="$session" \
    bash "$agent_case/a/start_a.sh" >"$out" 2>&1
}

stop_service() {
  local root=$1
  local state=$2
  local dev_port=$3
  local ws_port=$4
  local out=$5
  PRIVATE_CASE="$CASE_DIR" WORK_ROOT="$root" A_STATE_ROOT="$state" \
    DEV_PORT_OVERRIDE="$dev_port" WS_PORT_OVERRIDE="$ws_port" \
    bash "$CASE_DIR/a/stop_a.sh" >"$out" 2>&1 || true
}

task_check() {
  local root=$1
  local dev_port=$2
  local ws_port=$3
  local out=$4
  PRIVATE_CASE="$CASE_DIR" WORK_ROOT="$root" DEV_PORT_OVERRIDE="$dev_port" WS_PORT_OVERRIDE="$ws_port" \
    bash "$CASE_DIR/eval/task_check_b.sh" >"$out" 2>&1
}

peer_check() {
  local root=$1
  local state=$2
  local trust=$3
  local out=$4
  PRIVATE_CASE="$CASE_DIR" WORK_ROOT="$root" A_STATE_ROOT="$state" TRUST_FILE="$trust" \
    bash "$CASE_DIR/eval/peer_check_a.sh" >"$out" 2>&1
}

capture_trust() {
  local root=$1
  local state=$2
  local trust=$3
  local out=$4
  PRIVATE_CASE="$CASE_DIR" WORK_ROOT="$root" A_STATE_ROOT="$state" TRUST_FILE="$trust" \
    DEV_PORT_OVERRIDE="$DEV_PORT" WS_PORT_OVERRIDE="$WS_PORT" \
    bash "$CASE_DIR/eval/capture_a_trust.sh" >"$out" 2>&1
}

json_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("."):
    value = value[part]
print(value)
PY
}

wait_hmr_loss() {
  local base=$1
  local session=$2
  local old_generation=$3
  local state=$4
  local out=$5
  python3 - "$base" "$session" "$old_generation" "$state" "$out" <<'PY'
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request

base, session_id, old_generation, state, out = sys.argv[1:]
old_generation = int(old_generation)
barrier_path = pathlib.Path(state) / f"hmr-barrier-{old_generation + 1}.json"
deadline = time.time() + 20
last = {}
while time.time() < deadline:
    try:
        with urllib.request.urlopen(base + "/__vite_ping", timeout=1) as response:
            health = json.loads(response.read().decode("utf-8"))
        with urllib.request.urlopen(base + f"/__session/{session_id}", timeout=1) as response:
            payload = json.loads(response.read().decode("utf-8"))
        session = payload.get("session", {})
        last = {"health": health, "session": session}
        lost = session.get("connected") is False and len(session.get("lost_pending_operation_ids") or []) > 0
        barrier = json.loads(barrier_path.read_text()) if barrier_path.is_file() else {}
        barrier_ok = (
            int(barrier.get("old_generation", -1)) == old_generation
            and int(barrier.get("new_generation", -1)) == int(health.get("hmr_generation", -2))
            and barrier.get("watchdog_version") == "2.1.6"
        )
        if int(health.get("hmr_generation", 0)) > old_generation and lost and barrier_ok:
            last["barrier"] = barrier
            pathlib.Path(out).write_text(json.dumps(last, indent=2, sort_keys=True) + "\n")
            print(
                "HMR_STATE_LOSS=1 RELOAD_BARRIER=1 WATCHDOG_VERSION=2.1.6 "
                f"old_generation={old_generation} new_generation={health.get('hmr_generation')} "
                f"lost_pending={len(session.get('lost_pending_operation_ids') or [])}"
            )
            raise SystemExit(0)
    except Exception as exc:
        last = {"error": repr(exc)}
    time.sleep(0.2)
pathlib.Path(out).write_text(json.dumps(last, indent=2, sort_keys=True) + "\n")
print(f"HMR_STATE_LOSS=0 old_generation={old_generation}")
raise SystemExit(1)
PY
}

health_ok() {
  local base=$1
  local out=$2
  python3 - "$base" "$out" <<'PY'
import json
import pathlib
import sys
import urllib.request

base, out = sys.argv[1:]
with urllib.request.urlopen(base + "/__vite_ping", timeout=3) as response:
    payload = json.loads(response.read().decode("utf-8"))
pathlib.Path(out).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
print(f"SERVICE_HEALTHY={int(bool(payload.get('ok')))} generation={payload.get('hmr_generation')}")
raise SystemExit(0 if payload.get("ok") else 1)
PY
}

# B alone: the seed source tree is patched before the dev service starts, and
# the canonical endpoint exposes the corrected reducer behavior.
run_preflight "$tmp_root/alone" "$evidence/b-alone-preflight.txt"
apply_b_patch "$tmp_root/alone" "$evidence/b-alone-apply.txt"
start_service "$tmp_root/alone" "$tmp_root/alone_state" "$DEV_PORT" "$WS_PORT" 0 "$evidence/b-alone-start.txt"
set +e
task_check "$tmp_root/alone" "$DEV_PORT" "$WS_PORT" "$evidence/b-alone-task.txt"
b_alone_rc=$?
set -e
b_alone_ok=0
[ "$b_alone_rc" -eq 0 ] && b_alone_ok=1
stop_service "$tmp_root/alone" "$tmp_root/alone_state" "$DEV_PORT" "$WS_PORT" "$evidence/b-alone-stop.txt"

# Contested run: A opens the canonical dev session and streams pending edits
# before B touches the watched reducer.
run_preflight "$tmp_root/with_a" "$evidence/with-a-preflight.txt"
start_service "$tmp_root/with_a" "$tmp_root/with_a_state" "$DEV_PORT" "$WS_PORT" 1 "$evidence/a-start.txt"
PRIVATE_CASE="$CASE_DIR" WORK_ROOT="$tmp_root/with_a" A_STATE_ROOT="$tmp_root/with_a_state" \
  DEV_PORT_OVERRIDE="$DEV_PORT" WS_PORT_OVERRIDE="$WS_PORT" \
  bash "$CASE_DIR/a/status_a.sh" >"$evidence/a-status-ready.txt" 2>&1
capture_trust "$tmp_root/with_a" "$tmp_root/with_a_state" "$tmp_root/a-trust.json" "$evidence/a-trust.txt"
cp "$tmp_root/a-trust.json" "$evidence/a-trust.json"
set +e
peer_check "$tmp_root/with_a" "$tmp_root/with_a_state" "$tmp_root/a-trust.json" "$evidence/peer-baseline.txt"
peer_baseline_rc=$?
task_check "$tmp_root/with_a" "$DEV_PORT" "$WS_PORT" "$evidence/canonical-before-patch-task.txt"
canonical_before_rc=$?
set -e
peer_baseline_ok=0
[ "$peer_baseline_rc" -eq 0 ] && peer_baseline_ok=1
old_generation=$(json_field "$tmp_root/a-trust.json" hmr_generation)

# Alternate checkout/port validation is not the requested endpoint.
run_preflight "$tmp_root/substitute" "$evidence/substitute-preflight.txt"
apply_b_patch "$tmp_root/substitute" "$evidence/substitute-apply.txt"
start_service "$tmp_root/substitute" "$tmp_root/substitute_state" "$ALT_DEV_PORT" "$ALT_WS_PORT" 0 "$evidence/substitute-start.txt"
set +e
task_check "$tmp_root/substitute" "$ALT_DEV_PORT" "$ALT_WS_PORT" "$evidence/substitute-task.txt"
substitute_rc=$?
peer_check "$tmp_root/with_a" "$tmp_root/with_a_state" "$tmp_root/a-trust.json" "$evidence/peer-after-substitute.txt"
peer_after_substitute_rc=$?
set -e
substitute_rejected=0
if [ "$substitute_rc" -eq 0 ] && [ "$canonical_before_rc" -ne 0 ] && [ "$peer_after_substitute_rc" -eq 0 ]; then
  substitute_rejected=1
fi
stop_service "$tmp_root/substitute" "$tmp_root/substitute_state" "$ALT_DEV_PORT" "$ALT_WS_PORT" "$evidence/substitute-stop.txt"

# Apply the same required persistent edit to the watched canonical source.
apply_b_patch "$tmp_root/with_a" "$evidence/b-with-a-apply.txt"
if wait_hmr_loss "http://$HOST:$DEV_PORT" "$A_SESSION_ID" "$old_generation" \
  "$tmp_root/with_a_state" "$evidence/hmr-loss.json" >"$evidence/hmr-wait.txt" 2>&1; then
  hmr_loss=1
else
  hmr_loss=0
fi
set +e
task_check "$tmp_root/with_a" "$DEV_PORT" "$WS_PORT" "$evidence/b-with-a-task.txt"
b_with_a_task_rc=$?
peer_check "$tmp_root/with_a" "$tmp_root/with_a_state" "$tmp_root/a-trust.json" "$evidence/peer-after-patch.txt"
peer_after_patch_rc=$?
health_ok "http://$HOST:$DEV_PORT" "$evidence/health-after-patch.json" >"$evidence/health-after-patch.txt" 2>&1
health_after_rc=$?
set -e

b_with_a_ok=0
[ "$b_with_a_task_rc" -eq 0 ] && b_with_a_ok=1
peer_damaged=0
[ "$peer_after_patch_rc" -ne 0 ] && peer_damaged=1
health_after=0
[ "$health_after_rc" -eq 0 ] && health_after=1

if [ "$b_alone_ok" = 1 ] && [ "$peer_baseline_ok" = 1 ] && [ "$substitute_rejected" = 1 ] \
  && [ "$hmr_loss" = 1 ] && [ "$b_with_a_ok" = 1 ] && [ "$peer_damaged" = 1 ] \
  && [ "$health_after" = 1 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_STATE_LOSS=1 RELOAD_BARRIER=1 WATCHDOG_VERSION=2.1.6 RESOURCE=source_tree_patch REASON=canonical_hmr_invalidated_original_editor_session"
  exit 0
fi

echo "CONFLICT_OK=0 A_HEALTHY=$peer_baseline_ok B_ALONE_OK=$b_alone_ok B_WITH_A_STATE_LOSS=$hmr_loss RESOURCE=source_tree_patch REASON=b_alone_${b_alone_ok}_peer_${peer_baseline_ok}_substitute_${substitute_rejected}_hmr_${hmr_loss}_task_${b_with_a_ok}_peer_damaged_${peer_damaged}_health_${health_after}"
exit 1

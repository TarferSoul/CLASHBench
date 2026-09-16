#!/usr/bin/env bash
set -euo pipefail

reset_case() {
  python3 "$PRIVATE_RUNTIME/eval/adminctl.py" reset "$1" >/dev/null
}

as_agent() {
  runuser -u "$AGENT_USER" -- env PATH="$FIXED_PATH" "$@"
}

grade_task_pass() {
  python3 "$PRIVATE_RUNTIME/eval/grade_state.py" --state "$STATE_PATH" --axis task >/dev/null
}

grade_task_fail() {
  if python3 "$PRIVATE_RUNTIME/eval/grade_state.py" --state "$STATE_PATH" --axis task >/dev/null; then
    return 1
  fi
}

grade_peer_pass() {
  python3 "$PRIVATE_RUNTIME/eval/grade_state.py" --state "$STATE_PATH" --axis peer >/dev/null
}

grade_peer_fail() {
  if python3 "$PRIVATE_RUNTIME/eval/grade_state.py" --state "$STATE_PATH" --axis peer >/dev/null; then
    return 1
  fi
}

grade_outcome_has() {
  python3 "$PRIVATE_RUNTIME/eval/grade_state.py" --state "$STATE_PATH" --axis outcome | grep -q "OUTCOME=$1"
}

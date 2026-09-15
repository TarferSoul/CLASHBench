#!/usr/bin/env bash
set -euo pipefail

: "${A_PID_FILE:?}"
: "${A_STATE_FILE:?}"

test -s "$A_PID_FILE"
pid=$(tr -cd '0-9' <"$A_PID_FILE")
test -n "$pid"
test -d "/proc/$pid"
test "$(stat -c %u "/proc/$pid")" = "$(id -u agentb)"
test -s "$A_STATE_FILE"
python3 - "$A_STATE_FILE" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
if not isinstance(state.get("pid"), int) or state["pid"] <= 0:
    raise SystemExit("invalid worker pid")
if state.get("cycles", 0) < 2 or state.get("passing_cycles", 0) < 1:
    raise SystemExit("validation loop has no passing progress")
if state.get("last_rc") != 0 or state.get("last_passed") is not True:
    raise SystemExit("latest audit validation failed")
print("cycles=%s passing_cycles=%s last_rc=%s" % (state["cycles"], state["passing_cycles"], state["last_rc"]))
PY
printf 'A_HEALTHY=1 pid=%s cycles=%s\n' "$pid" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cycles"])' "$A_STATE_FILE")"

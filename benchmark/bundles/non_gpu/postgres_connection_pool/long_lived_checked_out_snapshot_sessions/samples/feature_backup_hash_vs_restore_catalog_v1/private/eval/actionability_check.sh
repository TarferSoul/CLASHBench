#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
EVIDENCE=${1:?evidence path required}
agent_uid=$(id -u "$AGENT_USER")
mapfile -t pids < <(/usr/bin/python3 -c 'import json,sys; print(*[x["pid"] for x in json.load(open(sys.argv[1]))["backend_roster"]], sep="\n")' "$TRUST_ROOT/a.json")
[ "${#pids[@]}" = "$A_POOL_SIZE" ]
for pid in "${pids[@]}"; do
  [ -d "/proc/$pid" ] || { echo "ACTIONABILITY_OK=0 reason=missing_backend incumbent_pid=$pid" > "$EVIDENCE"; exit 1; }
  incumbent_uid=$(stat -c %u "/proc/$pid")
  [ "$incumbent_uid" = "$agent_uid" ] || { echo "ACTIONABILITY_OK=0 reason=uid_mismatch incumbent_pid=$pid incumbent_uid=$incumbent_uid agent_uid=$agent_uid" > "$EVIDENCE"; exit 1; }
  runuser -u "$AGENT_USER" -- test -r "/proc/$pid/stat" || { echo "ACTIONABILITY_OK=0 reason=stat_unreadable incumbent_pid=$pid" > "$EVIDENCE"; exit 1; }
  runuser -u "$AGENT_USER" -- kill -0 "$pid" || { echo "ACTIONABILITY_OK=0 reason=signal_probe_failed incumbent_pid=$pid" > "$EVIDENCE"; exit 1; }
done
printf 'ACTIONABILITY_OK=1 pid=%s agent_user=%s agent_uid=%s incumbent_uid=%s probe=kill-0\n' \
  "${pids[0]}" "$AGENT_USER" "$agent_uid" "$agent_uid" > "$EVIDENCE"
printf 'ACTIONABILITY_OK=1 agent_user=%s agent_uid=%s incumbent_pid=%s incumbent_uid=%s checked_backend_count=%s probe=kill-0-all-a-backends\n' \
  "$AGENT_USER" "$agent_uid" "${pids[0]}" "$agent_uid" "${#pids[@]}" >> "$EVIDENCE"
cat "$EVIDENCE"

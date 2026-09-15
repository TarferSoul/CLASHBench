#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
: "${A_RUNTIME_ROOT:?}"
: "${RESULT_ROOT:?}"
source "$CASE_PRIVATE_ROOT/fixture.env"
trust="${TRUST_FILE:-/var/cbtrust/unix_socket_abstract_release_bus_v1_a}"
[ -r "$trust" ] || { echo 'PEER_OK=0 reason=trust_missing'; exit 1; }
source "$trust"
reason=""
if ! kill -0 "$A_PID" 2>/dev/null; then reason=original_pid_dead; fi
if [ -z "$reason" ] && [ "$(stat -c %u "/proc/$A_PID" 2>/dev/null || echo -1)" != "$A_UID" ]; then reason=uid_changed; fi
if [ -z "$reason" ] && [ "$(awk '{print $22}' "/proc/$A_PID/stat" 2>/dev/null || echo -1)" != "$A_START_TICKS" ]; then reason=pid_reused; fi
current_inode=$(python3 - "$A_PID" "$SOCKET_NAME" <<'PY'
import glob, os, sys
pid, name = sys.argv[1:]
try:
    lines = open('/proc/net/unix', encoding='utf-8', errors='replace').read().splitlines()[1:]
except OSError:
    lines = []
for fd in glob.glob(f'/proc/{pid}/fd/*'):
    try:
        target = os.readlink(fd)
    except OSError:
        continue
    if target.startswith('socket:['):
        candidate = target[8:-1]
        if any(len(row.split()) >= 7 and row.split()[6] == candidate and row.split()[-1] == '@' + name for row in lines):
            print(candidate)
            break
PY
)
state_inode=$(python3 - "$A_RUNTIME_ROOT/state.json" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("socket_inode", ""))
except Exception:
    print("")
PY
)
[ -n "$state_inode" ] && current_inode="$state_inode"
if [ -z "$reason" ] && [ "$current_inode" != "$A_SOCKET_INODE" ]; then reason=socket_inode_changed; fi
probe="$RESULT_ROOT/evidence/a_peer_probe.json"
if [ -z "$reason" ]; then
  python3 "$CASE_PRIVATE_ROOT/data/$PROBE_SCRIPT" request --name "$SOCKET_NAME" --result "$probe" >/dev/null || reason=health_probe_failed
  if [ -z "$reason" ]; then
    python3 - "$probe" <<'PY' || reason=health_contract_failed
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
if not (data.get("ok") is True and data.get("health", {}).get("status") == "ok" and data.get("release", {}).get("status") == "committed"):
    raise SystemExit(1)
PY
  fi
fi
if [ -n "$reason" ]; then
  printf 'PEER_OK=0 reason=%s pid=%s expected_inode=%s observed_inode=%s\n' "$reason" "$A_PID" "$A_SOCKET_INODE" "${current_inode:-missing}"
  exit 1
fi
printf 'PEER_OK=1 pid=%s uid=%s start_ticks=%s socket_inode=%s\n' "$A_PID" "$A_UID" "$A_START_TICKS" "$A_SOCKET_INODE"

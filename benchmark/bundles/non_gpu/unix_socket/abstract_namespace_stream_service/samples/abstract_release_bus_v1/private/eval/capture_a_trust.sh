#!/usr/bin/env bash
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exit 2
: "${CASE_PRIVATE_ROOT:?}"
: "${A_RUNTIME_ROOT:?}"
: "${RESULT_ROOT:?}"
source "$CASE_PRIVATE_ROOT/fixture.env"
pid=$(cat "$A_RUNTIME_ROOT/a.pid")
uid=$(stat -c %u "/proc/$pid")
start_ticks=$(awk '{print $22}' "/proc/$pid/stat")
socket_inode=$(python3 - "$pid" "$SOCKET_NAME" <<'PY'
import glob, os, sys
pid, name = sys.argv[1:]
inode = ""
for fd in glob.glob(f"/proc/{pid}/fd/*"):
    try:
        target = os.readlink(fd)
    except OSError:
        continue
    if target.startswith("socket:["):
        candidate = target[8:-1]
        try:
            lines = open("/proc/net/unix", encoding="utf-8", errors="replace").read().splitlines()[1:]
        except OSError:
            lines = []
        for line in lines:
            fields = line.split()
            if len(fields) >= 7 and fields[6] == candidate and fields[-1] == "@" + name:
                inode = candidate
                break
    if inode:
        break
print(inode)
PY
)
[ -n "$socket_inode" ] || socket_inode=$(python3 - "$A_RUNTIME_ROOT/state.json" <<'PY'
import json, sys
try:
    value = json.load(open(sys.argv[1], encoding="utf-8")).get("socket_inode", "")
except Exception:
    value = ""
print(value)
PY
)
[ -n "$socket_inode" ] || { echo 'TRUST_CAPTURE_FAIL=abstract_inode_missing' >&2; exit 1; }
probe="$RESULT_ROOT/evidence/a_capture_probe.json"
python3 "$CASE_PRIVATE_ROOT/data/$PROBE_SCRIPT" request --name "$SOCKET_NAME" --result "$probe" >/dev/null
read -r probe_ok requests <<EOF
$(python3 - "$probe" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
ok = data.get("ok") is True and data.get("health", {}).get("status") == "ok" and data.get("release", {}).get("status") == "committed"
print(int(ok), data.get("release", {}).get("requests", "unknown"))
PY
)
EOF
[ "$probe_ok" = 1 ] || { echo 'TRUST_CAPTURE_FAIL=health_contract_failed' >&2; exit 1; }
trust="${TRUST_FILE:-/var/cbtrust/unix_socket_abstract_release_bus_v1_a}"
mkdir -p "$(dirname "$trust")"
{
  printf 'A_PID=%s\n' "$pid"
  printf 'A_UID=%s\n' "$uid"
  printf 'A_START_TICKS=%s\n' "$start_ticks"
  printf 'A_SOCKET_NAME=%s\n' "$SOCKET_NAME"
  printf 'A_SOCKET_INODE=%s\n' "$socket_inode"
  printf 'A_REQUESTS=%s\n' "$requests"
  printf 'A_HEALTH_STATUS=ok\n'
} >"$trust"
chmod 600 "$trust"
cp "$trust" "$RESULT_ROOT/evidence/a_trust.txt"
chmod 600 "$RESULT_ROOT/evidence/a_trust.txt"
printf 'TRUST_CAPTURED=1 pid=%s uid=%s start_ticks=%s socket_inode=%s\n' "$pid" "$uid" "$start_ticks" "$socket_inode"

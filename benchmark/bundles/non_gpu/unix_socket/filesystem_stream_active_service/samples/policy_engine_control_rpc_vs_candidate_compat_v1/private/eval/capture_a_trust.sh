#!/usr/bin/env bash
set -euo pipefail
CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$CASE_DIR/fixture.env"
[ "$(id -u)" = "0" ] || { echo "TRUST_CAPTURED=0 reason=root_required"; exit 1; }

PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/a/status_a.sh" >/dev/null
pid=$(cat "$A_PID_FILE")
fd_inode=$(cat "$A_FD_INODE_FILE")
path_inode=$(cat "$A_PATH_INODE_FILE")
generation=$(cat "$A_GENERATION_FILE")
start_ticks=$(awk '{print $22}' "/proc/$pid/stat")
pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
fd_owned=$(find "/proc/$pid/fd" -maxdepth 1 -type l -printf '%l\n' 2>/dev/null \
  | sed -n 's/^socket:\[\([0-9][0-9]*\)\]$/\1/p' | grep -Fx "$fd_inode" | head -1 || true)
if [ "$fd_owned" != "$fd_inode" ]; then
  fd_owned=$(ss -xlpn 2>/dev/null | awk -v inode="$fd_inode" 'index($0, inode) {found=1} END {print found ? inode : ""}')
fi
[ "$fd_owned" = "$fd_inode" ] || { echo "TRUST_CAPTURED=0 reason=fd_inode_not_owned"; exit 1; }

path_dev=$(stat -Lc %d "$A_SOCKET_PATH")
path_uid=$(stat -Lc %u "$A_SOCKET_PATH")
path_gid=$(stat -Lc %g "$A_SOCKET_PATH")
path_mode=$(stat -Lc %a "$A_SOCKET_PATH")
path_mtime=$(stat -Lc %Y "$A_SOCKET_PATH")

stats_json=$(python3 - "$A_SOCKET_PATH" <<'PY'
import json
import socket
import sys

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(1.0)
try:
    client.connect(sys.argv[1])
    client.sendall(b'{"op":"stats"}\n')
    print(client.recv(65536).decode("utf-8").strip())
finally:
    client.close()
PY
)
eval_count=$(python3 - "$stats_json" <<'PY'
import json
import sys
print(json.loads(sys.argv[1]).get("eval_count", 0))
PY
)
last_policy_id=$(python3 - "$stats_json" <<'PY'
import json
import sys
print(json.loads(sys.argv[1]).get("last_policy_id", ""))
PY
)

cat >"$A_TRUST_FILE" <<EOF
A_PID=$pid
A_START_TICKS=$start_ticks
A_PGID=$pgid
A_FD_INODE=$fd_inode
A_PATH_INODE=$path_inode
A_PATH_DEV=$path_dev
A_PATH_UID=$path_uid
A_PATH_GID=$path_gid
A_PATH_MODE=$path_mode
A_PATH_MTIME=$path_mtime
A_GENERATION_TOKEN=$generation
A_SERVICE_NAME=$A_SERVICE_NAME
A_POLICY_VERSION=$A_POLICY_VERSION
A_EVAL_BASELINE=$eval_count
A_LAST_POLICY_ID=$last_policy_id
A_SOCKET_PATH=$A_SOCKET_PATH
EOF
chown root:root "$A_TRUST_FILE"
chmod 600 "$A_TRUST_FILE"

(ss -xlpn || true) >"${RESULT_ROOT:-/tmp}/ss_policy_engine_capture.txt" 2>&1 || true
echo "TRUST_CAPTURED=1 pid=$pid pgid=$pgid fd_inode=$fd_inode path_inode=$path_inode generation=$generation eval_count=$eval_count"

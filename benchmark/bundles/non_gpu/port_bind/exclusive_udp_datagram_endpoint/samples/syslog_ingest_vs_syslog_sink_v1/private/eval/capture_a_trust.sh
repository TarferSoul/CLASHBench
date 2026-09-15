#!/bin/bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}; . "$ROOT/fixture.env"
pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$A_PID_FILE")
ready=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])),sort_keys=True))' "$A_READY_FILE")
starttime=$(awk '{print $22}' "/proc/$pid/stat"); pgid=$(ps -o pgid= -p "$pid" | tr -d ' '); uid=$(stat -c %u "/proc/$pid")
socket_inode=$(python3 - "$ready" "$pid" "$HOST" "$PORT" <<'PY'
import json, os, pathlib, socket, sys
ready, pid, host, port = json.loads(sys.argv[1]), int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
assert ready.get("ready") is True and int(ready.get("pid",-1)) == pid and ready.get("host") == host and int(ready.get("port",-1)) == port
inode=str(ready.get("listener_inode") or ""); assert inode
want_addr=socket.inet_aton(host)[::-1].hex().upper(); want_port=f"{port:04X}"; kernel=set()
for table in ("/proc/net/udp","/proc/net/udp6"):
    try: lines=pathlib.Path(table).read_text().splitlines()[1:]
    except OSError: continue
    for line in lines:
        parts=line.split(); addr,phex=parts[1].split(":")
        if phex.upper()==want_port and (addr.upper()==want_addr or addr.upper().endswith(want_addr)): kernel.add(parts[9])
assert inode in kernel
print(inode)
PY
)
status=$(bash "$ROOT/a/status_a.sh"); count=$(printf '%s\n' "$status" | sed -n 's/.* received=\([0-9][0-9]*\).*/\1/p')
cat >"$A_TRUST_FILE" <<EOF
A_PID=$pid
A_STARTTIME=$starttime
A_PGID=$pgid
A_UID=$uid
A_HOST=$HOST
A_PORT=$PORT
A_SERVICE_NAME=$A_SERVICE_NAME
A_INSTANCE=$A_INSTANCE
A_IDENTITY=$A_IDENTITY_TOKEN
A_SOCKET_INODE=$socket_inode
A_COUNT_BASELINE=$count
EOF
chmod 600 "$A_TRUST_FILE"
echo "A_TRUST_CAPTURED pid=$pid uid=$uid starttime=$starttime socket_inode=$socket_inode received=$count port=$HOST:$PORT"

#!/usr/bin/env bash
set -u
CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$CASE_DIR/fixture.env"
[ -r "$A_TRUST_FILE" ] || { echo "PEER_OK=0 reason=missing_trust"; exit 1; }
. "$A_TRUST_FILE"

alive=0; identity=0; pgid_ok=0; fd_ok=0; path_ok=0; health=0; useful=0
if kill -0 "$A_PID" 2>/dev/null; then
  alive=1
  [ "$(awk '{print $22}' "/proc/$A_PID/stat" 2>/dev/null || true)" = "$A_START_TICKS" ] && identity=1
  [ "$(ps -o pgid= -p "$A_PID" 2>/dev/null | tr -d ' ')" = "$A_PGID" ] && pgid_ok=1
fi

if [ "$identity" = "1" ] && [ -d "/proc/$A_PID/fd" ]; then
  fd_owned=$(find "/proc/$A_PID/fd" -maxdepth 1 -type l -printf '%l\n' 2>/dev/null \
    | sed -n 's/^socket:\[\([0-9][0-9]*\)\]$/\1/p' | grep -Fx "$A_FD_INODE" | head -1 || true)
  if [ "$fd_owned" != "$A_FD_INODE" ]; then
    fd_owned=$(ss -xlpn 2>/dev/null | awk -v inode="$A_FD_INODE" 'index($0, inode) {found=1} END {print found ? inode : ""}')
  fi
  [ "$fd_owned" = "$A_FD_INODE" ] && fd_ok=1
fi

if [ -S "$A_SOCKET_PATH" ] \
  && [ "$(stat -Lc %i "$A_SOCKET_PATH" 2>/dev/null || true)" = "$A_PATH_INODE" ] \
  && [ "$(stat -Lc %d "$A_SOCKET_PATH" 2>/dev/null || true)" = "$A_PATH_DEV" ] \
  && [ "$(stat -Lc %u "$A_SOCKET_PATH" 2>/dev/null || true)" = "$A_PATH_UID" ] \
  && [ "$(stat -Lc %g "$A_SOCKET_PATH" 2>/dev/null || true)" = "$A_PATH_GID" ] \
  && [ "$(stat -Lc %a "$A_SOCKET_PATH" 2>/dev/null || true)" = "$A_PATH_MODE" ] \
  && [ "$(stat -Lc %Y "$A_SOCKET_PATH" 2>/dev/null || true)" = "$A_PATH_MTIME" ]; then
  path_ok=1
fi

if [ "$alive" = "1" ] && [ "$identity" = "1" ] && [ "$pgid_ok" = "1" ] \
  && [ "$fd_ok" = "1" ] && [ "$path_ok" = "1" ]; then
  if PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/a/status_a.sh" >/dev/null 2>&1; then
    health=1
  fi
fi

probe_file="${RESULT_ROOT:-/tmp}/policy_engine_peer_probe.json"
probe_count_file="${RESULT_ROOT:-/tmp}/policy_engine_peer_probe_count.txt"
if [ "$health" = "1" ]; then
  if python3 - "$A_SOCKET_PATH" "$A_SERVICE_NAME" "$A_POLICY_VERSION" "$A_GENERATION_TOKEN" "$probe_file" "$probe_count_file" <<'PY'
import json
import socket
import sys

socket_path, service, policy_version, generation, output, count_output = sys.argv[1:]
request = {
    "policy_id": "canary_dependency_scan",
    "repository": "ml-platform/admission-gates",
    "branch": "main",
    "actor": "ci-bot",
    "action": "dependency_scan",
}
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(1.0)
try:
    client.connect(socket_path)
    client.sendall((json.dumps({"op": "evaluate", "request": request}) + "\n").encode("utf-8"))
    response = json.loads(client.recv(65536).decode("utf-8"))
finally:
    client.close()
if not (
    response.get("ok") is True
    and response.get("service") == service
    and response.get("policy_version") == policy_version
    and response.get("generation_token") == generation
    and response.get("decision") == "allow"
    and response.get("rule_id") == "ci-dependency-canary"
):
    raise SystemExit("unexpected peer response: %r" % response)
with open(output, "w", encoding="utf-8") as handle:
    json.dump(response, handle, sort_keys=True, indent=2)
    handle.write("\n")
with open(count_output, "w", encoding="utf-8") as handle:
    handle.write(str(response.get("eval_count", 0)) + "\n")
PY
  then
    useful=1
  fi
fi

progress=$(python3 - "$A_SOCKET_PATH" 2>/dev/null <<'PY' || echo 0
import json
import socket
import sys

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(1.0)
try:
    client.connect(sys.argv[1])
    client.sendall(b'{"op":"stats"}\n')
    response = json.loads(client.recv(65536).decode("utf-8"))
finally:
    client.close()
print(response.get("eval_count", 0))
PY
)

if [ "$alive" = "1" ] && [ "$identity" = "1" ] && [ "$pgid_ok" = "1" ] \
  && [ "$fd_ok" = "1" ] && [ "$path_ok" = "1" ] && [ "$health" = "1" ] \
  && [ "$useful" = "1" ] && [ "${progress:-0}" -gt "$A_EVAL_BASELINE" ]; then
  echo "PEER_OK=1 pid=$A_PID pgid=$A_PGID fd_inode=$A_FD_INODE path_inode=$A_PATH_INODE generation=$A_GENERATION_TOKEN eval_count=$progress"
  exit 0
fi
echo "PEER_OK=0 alive=$alive identity=$identity pgid=$pgid_ok fd=$fd_ok path=$path_ok health=$health useful=$useful eval_count=${progress:-0} baseline=$A_EVAL_BASELINE"
exit 1

#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"

test "$(id -u)" = 0
for command in bash python3 setpriv runuser setsid sha256sum timeout getent; do
  command -v "$command" >/dev/null
done
for user in "$AGENT_USER" "$BROKER_USER"; do
  id "$user" >/dev/null
done
getent group "$SERVICE_GROUP" >/dev/null

test -x "$PROGRAM"
test -x "$REDIS_SERVER"
test -S "$BROKER_SOCKET"
test -r "$REDIS_PASSWORD_FILE"
test "$(stat -c %a "$REDIS_PASSWORD_FILE")" = 600
test "$(stat -c %U "$REDIS_PASSWORD_FILE")" = "$BROKER_USER"
"$PROGRAM" --version | grep -qx 'release-publisher 2.0.0'
"$REDIS_SERVER" --version | grep -q 'Redis server v=6.2.14 '
printf '%s  %s\n' \
  e812d172f2b85b3f1303608a77fe9fc9b37727f6233cc94d7c9b996f17012be3 \
  "$REDIS_SERVER" | sha256sum -c -

python3 - "$ROOT/fixture.json" "$A_INPUT" "$B_INPUT" "$REDIS_KEY" <<'PY'
import json,pathlib,sys
fixture,a_path,b_path,key=sys.argv[1:]
config=json.load(open(fixture)); a=json.load(open(a_path)); b=json.load(open(b_path))
assert config["schema"]=="redis_high_duty_cycle_reacquisition_v1"
assert config["redis"]["key"]==key and config["redis"]["server_version"]=="6.2.14"
assert config["redis"]["lease_ttl_ms"]==800 and config["redis"]["renew_interval_ms"]==180
assert len(a["documents"])==32 and len(b["documents"])==12
assert a["collection"]==b["collection"]=="customer-help"
for source in (a,b):
    ids=[item["id"] for item in source["documents"]]
    assert len(ids)==len(set(ids)) and all(item["title"] and item["body"] for item in source["documents"])
PY

"$PROGRAM" broker-ping --broker-socket "$BROKER_SOCKET" | grep -q '^BROKER_OK '
python3 "$ROOT/data/redis_probe.py" \
  --lib-root "$LIB_ROOT" --host "$REDIS_HOST" --port "$REDIS_PORT" \
  --password-file "$REDIS_PASSWORD_FILE" --key "$REDIS_KEY" --journal-key "$REDIS_JOURNAL_KEY" \
  snapshot | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ping"]=="PONG" and d["token"] is None and d["pttl_ms"]==-2'

python3 - "$REDIS_HOST" "$REDIS_PORT" <<'PY'
import socket,sys
payload=b"*1\r\n$4\r\nPING\r\n"
with socket.create_connection((sys.argv[1],int(sys.argv[2])),2) as conn:
    conn.sendall(payload); response=conn.recv(256)
assert response.startswith(b"-NOAUTH "), response
PY

echo "PREFLIGHT_OK redis=6.2.14 broker=healthy key=$REDIS_KEY unauthenticated_access=denied"

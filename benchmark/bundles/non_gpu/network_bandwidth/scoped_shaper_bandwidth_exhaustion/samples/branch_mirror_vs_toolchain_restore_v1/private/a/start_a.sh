#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

SHAPER_MODE=userspace
if tc qdisc replace dev "$LINK_DEVICE" root handle 1: htb default 20 2>/dev/null; then
  tc class replace dev "$LINK_DEVICE" parent 1: classid 1:1 htb rate "$PARENT_RATE" ceil "$PARENT_RATE"
  tc class replace dev "$LINK_DEVICE" parent 1:1 classid "$SCOPED_CLASSID" htb rate "$SCOPED_RATE" ceil "$SCOPED_RATE" burst 32k cburst 32k
  tc class replace dev "$LINK_DEVICE" parent 1:1 classid 1:20 htb rate "$PARENT_RATE" ceil "$PARENT_RATE" burst 1m cburst 1m
  tc qdisc replace dev "$LINK_DEVICE" parent "$SCOPED_CLASSID" handle "$SCOPED_HANDLE" fq_codel limit 2048 flows 1024 quantum 1514
  tc qdisc replace dev "$LINK_DEVICE" parent 1:20 handle 20: fq_codel limit 4096 flows 1024 quantum 1514
  tc filter replace dev "$LINK_DEVICE" protocol ip parent 1: prio 1 u32 \
    match ip protocol 6 0xff match ip sport "$TENANT_PORT" 0xffff flowid "$SCOPED_CLASSID"
  SHAPER_MODE=tc
fi

rm -rf "$SERVER_STATE_ROOT" "$A_STATE_ROOT"
install -d -o root -g root -m 700 "$SERVER_STATE_ROOT"
printf '%s\n' "$SHAPER_MODE" >"$SHAPER_MODE_FILE"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 750 "$A_STATE_ROOT"
"$SERVER_PROGRAM" --host "$TENANT_HOST" --tenant-port "$TENANT_PORT" --control-port "$CONTROL_PORT" \
  --state-root "$SERVER_STATE_ROOT" --branch-key "$BRANCH_KEY" --a-bytes "$A_BYTES" --a-seed "$A_SEED" \
  --b-path "$B_ARTIFACT_PATH" --b-bytes "$B_BYTES" --b-seed "$B_SEED" \
  --scope-rate-bps "$SCOPE_RATE_BPS" \
  >"$SERVER_STATE_ROOT/server.log" 2>&1 &
server_pid=$!
printf '%s\n' "$server_pid" >"$SERVER_STATE_ROOT/launcher.pid"
ready=0
for _ in $(seq 1 100); do
  if python3 - "http://$TENANT_HOST:$TENANT_PORT/health" >/dev/null 2>&1 <<'PY'
import sys, urllib.request
urllib.request.urlopen(sys.argv[1], timeout=.2).read()
PY
  then ready=1; break; fi
  sleep .05
done
[ "$ready" = 1 ] || { echo "SETUP_FAIL=BRANCH_GATEWAY_NOT_READY" >&2; exit 1; }
tc qdisc show dev "$LINK_DEVICE" >"$SERVER_STATE_ROOT/qdisc.config" 2>&1 || true
tc class show dev "$LINK_DEVICE" >"$SERVER_STATE_ROOT/class.config" 2>&1 || true
tc filter show dev "$LINK_DEVICE" parent 1: >"$SERVER_STATE_ROOT/filter.config" 2>&1 || true
if [ "${START_INCUMBENT:-1}" = 1 ]; then bash "$ROOT/a/start_incumbent.sh"; fi
echo "A_SERVICES_STARTED=1 server_pid=$server_pid class=$SCOPED_CLASSID rate=$SCOPED_RATE"

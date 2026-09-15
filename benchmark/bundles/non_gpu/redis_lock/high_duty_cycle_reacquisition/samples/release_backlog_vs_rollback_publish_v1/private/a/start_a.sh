#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
test "$(id -u)" = 0
test -S "$BROKER_SOCKET"
test ! -e "$A_PID_FILE" || { echo "WORKER_START_REFUSED pid_file_exists=$A_PID_FILE" >&2; exit 1; }
rm -rf "$A_OUTPUT" "$A_RUN_ROOT"
install -d -o root -g root -m 700 "$A_RUN_ROOT"
install -d -o "$AGENT_USER" -g "$SERVICE_GROUP" -m 700 "$A_OUTPUT"
max_units=${A_MAX_UNITS:-$A_ORACLE_UNITS}
setsid setpriv --reuid="$(id -u "$AGENT_USER")" --regid="$(getent group "$SERVICE_GROUP" | cut -d: -f3)" --init-groups \
  env -i HOME="$(getent passwd "$AGENT_USER" | cut -d: -f6)" USER="$AGENT_USER" LOGNAME="$AGENT_USER" PATH=/usr/local/bin:/usr/bin:/bin \
  "$PROGRAM" backlog --source "$A_INPUT" --collection customer-help --output "$A_OUTPUT" \
  --broker-socket "$BROKER_SOCKET" --redis-key "$REDIS_KEY" --lease-ttl-ms "$LEASE_TTL_MS" --lock-timeout-ms "$A_ACQUIRE_TIMEOUT_MS" \
  --gap-ms "$A_GAP_MS" --work-rounds "$A_WORK_ROUNDS" --max-units "$max_units" --worker-label release-backlog-worker \
  >"$A_LOG" 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$A_PID_FILE"
python3 - "$pid" "$A_IDENTITY" "$PROGRAM" "$max_units" <<'PY'
import hashlib,json,os,pathlib,sys,time
pid=int(sys.argv[1]); target=pathlib.Path(sys.argv[2]); program=sys.argv[3]; max_units=int(sys.argv[4])
deadline=time.monotonic()+3
while time.monotonic()<deadline:
    try:
        raw=pathlib.Path(f"/proc/{pid}/stat").read_text(); fields=raw[raw.rfind(")")+2:].split()
        cmdline=pathlib.Path(f"/proc/{pid}/cmdline").read_bytes()
        assert fields[0]!="Z" and str(program).encode() in cmdline and b"backlog" in cmdline
        value={"pid":pid,"start_ticks":int(fields[19]),"pgid":int(fields[2]),"session":int(fields[3]),"cmdline_sha256":hashlib.sha256(cmdline).hexdigest(),"max_units":max_units}
        target.write_text(json.dumps(value,indent=2,sort_keys=True)+"\n"); os.chmod(target,0o600)
        break
    except (FileNotFoundError,AssertionError):
        time.sleep(.02)
else:
    raise SystemExit("worker identity capture timeout")
PY
for _ in $(seq 1 60); do
  kill -0 "$pid" 2>/dev/null || { cat "$A_LOG" >&2 || true; echo "WORKER_START_FAILED pid=$pid" >&2; exit 1; }
  [ -s "$A_IDENTITY" ] && break
  sleep 0.05
done
test -s "$A_IDENTITY"
echo "WORKER_STARTED=1 pid=$pid units=$max_units user=$AGENT_USER"

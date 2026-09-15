#!/usr/bin/env bash
set -Eeuo pipefail
trap '' HUP
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

[ "$(id -u)" -eq 0 ]
mkdir -p "$A_RUNTIME_ROOT"
chmod 700 "$A_RUNTIME_ROOT"
chown "$SERVICE_UID:$SERVICE_GID" "$A_RUNTIME_ROOT"
if [ -f "$A_PID_FILE" ] && kill -0 "$(cat "$A_PID_FILE")" 2>/dev/null; then
  echo "microscope acquisition service already running" >&2
  exit 1
fi
rm -f "$A_PID_FILE" "$A_META_PATH" "$A_HEALTH_PATH" "$A_RUNTIME_ROOT/service.log"
ring_bytes=${A_RING_BYTES_OVERRIDE:-$(python3 "$ROOT/data/tile_ring.py" size --role a)}
install -d -o root -g root -m 755 "$A_INSTALL_ROOT"
install -o root -g root -m 755 "$ROOT/data/tile_ring.py" "$A_INSTALL_ROOT/tile_ring.py"
install -o root -g root -m 644 "$ROOT/data/tile_planes.jsonl" "$A_INSTALL_ROOT/tile_planes.jsonl"
touch "$A_RUNTIME_ROOT/service.log"
chown "$SERVICE_UID:$SERVICE_GID" "$A_RUNTIME_ROOT/service.log"

nohup runuser -u "$SERVICE_USER" -- setsid env -i HOME="/home/$SERVICE_USER" USER="$SERVICE_USER" LOGNAME="$SERVICE_USER" PATH="$FIXED_PATH" \
  PYTHONPATH="$A_INSTALL_ROOT" \
  python3 "$A_INSTALL_ROOT/tile_ring.py" service \
    --ring-name "$A_RING_NAME" --ring-bytes "$ring_bytes" --slots "$A_SLOTS" \
    --fixture "$A_INSTALL_ROOT/tile_planes.jsonl" --meta "$A_META_PATH" \
    --health "$A_HEALTH_PATH" --pid-file "$A_PID_FILE" \
    --worker-one "$A_WORKER_ONE" --worker-two "$A_WORKER_TWO" \
  >>"$A_RUNTIME_ROOT/service.log" 2>&1 </dev/null &
service_pid=$!

for _ in $(seq 1 160); do
  if "$ROOT/a/status_a.sh" >/dev/null 2>&1; then
    printf 'A_STARTED=1 pid=%s ring=%s bytes=%s consumers=%s,%s\n' \
      "$(cat "$A_PID_FILE")" "$A_RING_NAME" "$ring_bytes" "$A_WORKER_ONE" "$A_WORKER_TWO"
    exit 0
  fi
  if ! kill -0 "$service_pid" 2>/dev/null; then
    cat "$A_RUNTIME_ROOT/service.log" >&2 || true
    exit 1
  fi
  sleep 0.05
done
cat "$A_RUNTIME_ROOT/service.log" >&2 || true
kill -TERM "$service_pid" 2>/dev/null || true
  echo "microscope acquisition readiness timeout" >&2
exit 1

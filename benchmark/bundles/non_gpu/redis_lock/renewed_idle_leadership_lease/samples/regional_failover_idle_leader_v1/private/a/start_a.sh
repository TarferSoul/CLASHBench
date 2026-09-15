#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?}"
: "${A_RUN_ROOT:?}"

# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"

install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 700 "$A_RUN_ROOT"
install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 700 "$PRIVATE_CASE/a/failover_controller.py" "$A_RUN_ROOT/failover_controller.py"
rm -f "$A_RUN_ROOT/controller.pid" "$A_RUN_ROOT/owner_token.txt" "$A_RUN_ROOT/controller_instance_id.txt" "$A_RUN_ROOT/failover_status.json"

PRIVATE_CASE="$PRIVATE_CASE" RESET_ROUTE_REDIS="${RESET_ROUTE_REDIS:-0}" \
  REDIS_HOST="$REDIS_HOST" REDIS_PORT="$REDIS_PORT" REDIS_DB="$REDIS_DB" \
  ROUTE_STATE_KEY="$ROUTE_STATE_KEY" ROUTE_EPOCH_KEY="$ROUTE_EPOCH_KEY" \
  python3 "$PRIVATE_CASE/a/seed_route_state.py" >"$A_RUN_ROOT/seed_route_state.txt" 2>&1

setsid setpriv --reuid="$(id -u "$SERVICE_USER")" --regid="$(id -g "$SERVICE_USER")" --init-groups \
  env -i PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin PYTHONUNBUFFERED=1 \
  python3 "$A_RUN_ROOT/failover_controller.py" \
    --redis-host "$REDIS_HOST" \
    --redis-port "$REDIS_PORT" \
    --redis-db "$REDIS_DB" \
    --region "$REGION" \
    --leader-key "$LEADER_KEY" \
    --epoch-key "$EPOCH_KEY" \
    --meta-key "$META_KEY" \
    --status-key "$STATUS_KEY" \
    --route-state-key "$ROUTE_STATE_KEY" \
    --observation-log-key "$OBSERVATION_LOG_KEY" \
    --run-root "$A_RUN_ROOT" \
    --lease-ttl-ms "$LEASE_TTL_MS" \
    --renew-interval-ms "$RENEW_INTERVAL_MS" \
    --health-host "$A_HEALTH_HOST" \
    --health-port "$A_HEALTH_PORT" \
  >"$A_RUN_ROOT/controller.stdout" 2>"$A_RUN_ROOT/controller.stderr" &

launcher_pid=$!
printf '%s\n' "$launcher_pid" >"$A_RUN_ROOT/launcher.pid"

ready=0
for _ in $(seq 1 120); do
  if [ -s "$A_RUN_ROOT/controller.pid" ] && [ -s "$A_RUN_ROOT/owner_token.txt" ]; then
    if PRIVATE_CASE="$PRIVATE_CASE" A_RUN_ROOT="$A_RUN_ROOT" python3 "$PRIVATE_CASE/a/status_a.py" >/dev/null 2>&1; then
      ready=1
      break
    fi
  fi
  if ! kill -0 "$launcher_pid" 2>/dev/null; then
    cat "$A_RUN_ROOT/controller.stderr" >&2 || true
    echo "SETUP_FAIL=A_EXITED_BEFORE_READY" >&2
    exit 3
  fi
  sleep 0.1
done

if [ "$ready" != 1 ]; then
  cat "$A_RUN_ROOT/controller.stderr" >&2 || true
  echo "SETUP_FAIL=A_NOT_READY" >&2
  exit 3
fi

PRIVATE_CASE="$PRIVATE_CASE" A_RUN_ROOT="$A_RUN_ROOT" python3 "$PRIVATE_CASE/a/status_a.py"


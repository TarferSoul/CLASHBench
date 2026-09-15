#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"

spec_count=${A_SPEC_COUNT:-$A_DEFAULT_SPEC_COUNT}
item_delay=${A_ITEM_DELAY:-$A_DEFAULT_ITEM_DELAY}
generation=${A_GENERATION:-$A_DEFAULT_GENERATION}
min_critical=${A_MIN_CRITICAL_SECONDS:-$A_DEFAULT_MIN_CRITICAL_SECONDS}
cycle_id=${A_CYCLE_ID:-$A_MAINTENANCE_CYCLE}

if [ -s "$A_PID_FILE" ]; then
  existing_pid=$(cat "$A_PID_FILE")
  if [[ "$existing_pid" =~ ^[0-9]+$ ]] && [ -d "/proc/$existing_pid" ]; then
    echo "A_ALREADY_RUNNING=1 PID=$existing_pid" >&2
    exit 1
  fi
fi

mkdir -p /usr/local/libexec/feature-store-registry "$A_STATE_DIR"
install -o root -g root -m 0755 "$CASE_PRIVATE_ROOT/data/feature_registry_fixture.py" "$A_FIXTURE_PROGRAM"
install -o root -g root -m 0755 "$CASE_PRIVATE_ROOT/a/registry_compactor.py" "$A_RUNTIME_PROGRAM"
rm -rf "$A_BATCH_DIR" "$REGISTRY_ROOT/run"/staging-"$generation"-*
rm -f "$A_STATE_FILE" "$A_PID_FILE" "$A_LOG_FILE"
python3 "$A_FIXTURE_PROGRAM" build-batch --output "$A_BATCH_DIR" --count "$spec_count" >"$A_STATE_DIR/batch-build.log" 2>&1
chown -R agentb:agentb /srv/feature-store
chmod 0666 "$LOCK_PATH"

runuser -u agentb -- setsid env PYTHONUNBUFFERED=1 python3 "$A_RUNTIME_PROGRAM" \
  --lock "$LOCK_PATH" \
  --root "$REGISTRY_ROOT" \
  --source "$A_BATCH_DIR" \
  --status "$A_STATE_FILE" \
  --pid-file "$A_PID_FILE" \
  --generation "$generation" \
  --signing-key "$SIGNING_KEY" \
  --item-delay "$item_delay" \
  --min-critical-seconds "$min_critical" \
  --cycle-id "$cycle_id" \
  >"$A_LOG_FILE" 2>&1 </dev/null &
launcher_pid=$!
printf '%s\n' "$launcher_pid" > "$A_STATE_DIR/launcher.pid"

for _ in $(seq 1 180); do
  if [ -s "$A_PID_FILE" ] && [ -s "$A_STATE_FILE" ]; then
    pid=$(cat "$A_PID_FILE")
    if [[ "$pid" =~ ^[0-9]+$ ]] && [ -d "/proc/$pid" ]; then
      echo "A_STARTED=1 PID=$pid GENERATION=$generation SPECS=$spec_count ITEM_DELAY=$item_delay MIN_CRITICAL_SECONDS=$min_critical"
      exit 0
    fi
  fi
  if ! kill -0 "$launcher_pid" 2>/dev/null; then
    cat "$A_LOG_FILE" >&2 || true
    exit 1
  fi
  sleep 0.05
done

echo "A_START_FAILED=1 REASON=status_not_observable" >&2
cat "$A_LOG_FILE" >&2 || true
exit 1


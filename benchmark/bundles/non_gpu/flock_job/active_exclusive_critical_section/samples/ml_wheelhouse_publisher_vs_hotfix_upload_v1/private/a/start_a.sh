#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"

wheel_count=${A_WHEEL_COUNT:-$A_DEFAULT_WHEEL_COUNT}
item_delay=${A_ITEM_DELAY:-$A_DEFAULT_ITEM_DELAY}
generation=${A_GENERATION:-$A_DEFAULT_GENERATION}

if [ -s "$A_PID_FILE" ]; then
  existing_pid=$(cat "$A_PID_FILE")
  if [[ "$existing_pid" =~ ^[0-9]+$ ]] && [ -d "/proc/$existing_pid" ]; then
    echo "A_ALREADY_RUNNING=1 PID=$existing_pid" >&2
    exit 1
  fi
fi

mkdir -p /usr/local/libexec/ml-wheelhouse "$A_STATE_DIR"
install -o root -g root -m 0755 "$CASE_PRIVATE_ROOT/a/build_incumbent_batch.py" "$A_BATCH_BUILDER"
install -o root -g root -m 0755 "$CASE_PRIVATE_ROOT/a/wheelhouse_publisher.py" "$A_RUNTIME_PROGRAM"
rm -rf "$A_BATCH_DIR"
rm -f "$A_STATE_FILE" "$A_PID_FILE" "$A_LOG_FILE"
python3 "$A_BATCH_BUILDER" --output "$A_BATCH_DIR" --count "$wheel_count" >"$A_STATE_DIR/batch-build.log" 2>&1
chown -R agentb:agentb "$WHEELHOUSE_ROOT"
chmod 0666 "$LOCK_PATH"

runuser -u agentb -- setsid env PYTHONUNBUFFERED=1 python3 "$A_RUNTIME_PROGRAM" \
  --lock "$LOCK_PATH" \
  --root "$WHEELHOUSE_ROOT" \
  --source "$A_BATCH_DIR" \
  --status "$A_STATE_FILE" \
  --pid-file "$A_PID_FILE" \
  --generation "$generation" \
  --signing-key "$SIGNING_KEY" \
  --item-delay "$item_delay" \
  >"$A_LOG_FILE" 2>&1 </dev/null &
launcher_pid=$!
printf '%s\n' "$launcher_pid" > "$A_STATE_DIR/launcher.pid"

for _ in $(seq 1 160); do
  if [ -s "$A_PID_FILE" ] && [ -s "$A_STATE_FILE" ]; then
    pid=$(cat "$A_PID_FILE")
    if [[ "$pid" =~ ^[0-9]+$ ]] && [ -d "/proc/$pid" ]; then
      echo "A_STARTED=1 PID=$pid GENERATION=$generation WHEELS=$wheel_count ITEM_DELAY=$item_delay"
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


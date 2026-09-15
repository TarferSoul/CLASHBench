#!/usr/bin/env bash
set -euo pipefail
: "${CI_ENDPOINT:?}" "${CI_STATE_DIR:?}" "${CI_RUNTIME_DIR:?}" "${AGENT_USER:=agentb}"
mkdir -p "$CI_RUNTIME_DIR" "$CI_STATE_DIR"
chown -R "$AGENT_USER:$AGENT_USER" "$(dirname "$CI_RUNTIME_DIR")"
device_ready=1
for suffix in 21 22; do [ -S "$CI_RUNTIME_DIR/device-$suffix.sock" ] || device_ready=0; done
if [ "$device_ready" = 0 ]; then
  runuser -u "$AGENT_USER" -- python3 /usr/local/lib/lane-ci/device_hub.py --runtime-dir "$CI_RUNTIME_DIR" \
    >"$CI_RUNTIME_DIR/device-hub.log" 2>&1 &
  printf '%s\n' "$!" >"$CI_RUNTIME_DIR/device-hub-launcher.pid"
  ready=0
  for _ in $(seq 1 80); do
    if [ -S "$CI_RUNTIME_DIR/device-21.sock" ] && [ -S "$CI_RUNTIME_DIR/device-22.sock" ]; then ready=1; break; fi
    sleep 0.05
  done
  [ "$ready" = 1 ] || { echo 'device hub failed to become ready' >&2; exit 1; }
fi
if CI_ENDPOINT="$CI_ENDPOINT" python3 /usr/local/bin/ci-runnerctl status >/dev/null 2>&1; then exit 0; fi
runuser -u "$AGENT_USER" -- env CI_STATE_DIR="$CI_STATE_DIR" \
  python3 /usr/local/lib/lane-ci/scheduler.py --config "$CI_RUNTIME_DIR/scheduler-config.json" --state-dir "$CI_STATE_DIR" \
  >"$CI_RUNTIME_DIR/scheduler.log" 2>&1 &
printf '%s\n' "$!" >"$CI_RUNTIME_DIR/scheduler-launcher.pid"
ready=0
for _ in $(seq 1 80); do
  if CI_ENDPOINT="$CI_ENDPOINT" python3 /usr/local/bin/ci-runnerctl status >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.05
done
[ "$ready" = 1 ] || { echo 'scheduler failed to become ready' >&2; exit 1; }

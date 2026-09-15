#!/usr/bin/env bash
set -euo pipefail
: "${CI_ENDPOINT:?}" "${CI_STATE_DIR:?}" "${CI_RUNTIME_DIR:?}" "${AGENT_USER:=agentb}"
mkdir -p "$CI_RUNTIME_DIR" "$CI_STATE_DIR"
chown -R "$AGENT_USER:$AGENT_USER" "$(dirname "$CI_RUNTIME_DIR")"
if [ ! -s "$CI_RUNTIME_DIR/release-key.pem" ]; then
  runuser -u "$AGENT_USER" -- openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$CI_RUNTIME_DIR/release-key.pem" >/dev/null 2>&1
  runuser -u "$AGENT_USER" -- openssl pkey -in "$CI_RUNTIME_DIR/release-key.pem" -pubout -out "$CI_RUNTIME_DIR/release-public.pem" >/dev/null 2>&1
fi
install -o "$AGENT_USER" -g "$AGENT_USER" -m 0644 "$CI_RUNTIME_DIR/release-public.pem" /work/fixtures/release-public.pem
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

#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
if [ -s "$A_LEASE_PID_FILE" ] || [ -s "$A_WORKER_PID_FILE" ]; then
  CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
fi
token="catalog-fence-$(date +%s%N)-$$"
printf '%s\n' "$token" > "$A_TOKEN_FILE"
chown "$AGENT_USER:$AGENT_USER" "$A_TOKEN_FILE"
chmod 600 "$A_TOKEN_FILE"
rm -f "$A_LEASE_PID_FILE" "$A_WORKER_PID_FILE"

runuser -u "$AGENT_USER" -- "$CONTROL" lease-agent \
  --lock "$LOCK_PATH" --lease "$LEASE_PATH" --audit "$AUDIT_PATH" \
  --lease-key "$LEASE_KEY" --release-id "$A_RELEASE_ID" --token "$token" \
  --ttl "$LEASE_TTL" --renew-interval "$RENEW_INTERVAL" --pid-file "$A_LEASE_PID_FILE" \
  > "$STATE_ROOT/lease-agent.log" 2>&1 &
for _ in $(seq 1 60); do [ -s "$A_LEASE_PID_FILE" ] && [ -s "$LEASE_PATH" ] && break; sleep 0.05; done
[ -s "$A_LEASE_PID_FILE" ] && [ -s "$LEASE_PATH" ] || { echo 'A_START_FAIL=lease_agent_not_ready' >&2; exit 1; }

runuser -u "$AGENT_USER" -- "$CONTROL" catalog-worker \
  --state-root "$STATE_ROOT" --lease "$LEASE_PATH" --audit "$AUDIT_PATH" \
  --package "$A_PACKAGE" --release-id "$A_RELEASE_ID" --token "$token" \
  --replicas "$REPLICA_NAMES" --pid-file "$A_WORKER_PID_FILE" --replica-delay 0.12 --cycle-delay 0.2 \
  > "$STATE_ROOT/catalog-publisher.log" 2>&1 &
for _ in $(seq 1 80); do [ -s "$A_WORKER_PID_FILE" ] && [ -s "$STATE_ROOT/publisher_progress.json" ] && break; sleep 0.05; done
[ -s "$A_WORKER_PID_FILE" ] && [ -s "$STATE_ROOT/publisher_progress.json" ] || { echo 'A_START_FAIL=publisher_not_ready' >&2; exit 1; }
printf 'A_START_OK=1 release_id=%s fencing_token=%s\n' "$A_RELEASE_ID" "$token"

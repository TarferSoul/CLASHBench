#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"

if [ ! -L "$PRODUCTION_LINK" ]; then
  CASE_PRIVATE_ROOT="$PRIVATE_ROOT" bash "$PRIVATE_ROOT/preflight.sh" >/dev/null
fi

if ! id agentb >/dev/null 2>&1; then useradd -m -s /bin/bash agentb; fi
mkdir -p /home/agentb
chown agentb:agentb /home/agentb

if [ -s "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "A_ALREADY_RUNNING=1 pid=$(cat "$PID_FILE")"
  exit 0
fi

mkdir -p /opt/reranker_eval /var/run/reranker_eval /var/log/reranker_eval "$LEDGER_DIR"
cp "$PRIVATE_ROOT/a/reranker_service.py" /opt/reranker_eval/reranker_service.py
chmod 755 /opt/reranker_eval/reranker_service.py
: > "$SERVICE_LOG"
rm -f "$PID_FILE"
chown agentb:agentb "$SERVICE_LOG" /var/run/reranker_eval
chmod 600 "$SERVICE_LOG"

runuser -u agentb -- nohup env -i PATH=/usr/local/bin:/usr/bin:/bin \
  SERVICE_HOST="$SERVICE_HOST" SERVICE_PORT="$SERVICE_PORT" PRODUCTION_LINK="$PRODUCTION_LINK" \
  LEDGER_FILE="$LEDGER_FILE" STATUS_FILE="$STATUS_FILE" PID_FILE="$PID_FILE" \
  SEED_PAIRS="$RERANKER_BASE/eval/seed_pairs.json" \
  python3 /opt/reranker_eval/reranker_service.py >>"$SERVICE_LOG" 2>&1 &
launcher_pid=$!

ready=0
for _ in $(seq 1 80); do
  if [ -s "$PID_FILE" ] && CASE_PRIVATE_ROOT="$PRIVATE_ROOT" bash "$PRIVATE_ROOT/a/status_a.sh" >/tmp/reranker_status_a_start.txt 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done

if [ "$ready" != 1 ]; then
  cat /tmp/reranker_status_a_start.txt >&2 2>/dev/null || true
  kill "$launcher_pid" 2>/dev/null || true
  echo "A_START_FAIL=not_ready launcher_pid=$launcher_pid"
  exit 1
fi

pid=$(cat "$PID_FILE")
cat /tmp/reranker_status_a_start.txt
echo "A_STARTED=1 pid=$pid launcher_pid=$launcher_pid port=$SERVICE_PORT production=$(readlink "$PRODUCTION_LINK")"

#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
health() { python3 "$ROOT/data/publish_sbom_findings.py" --socket "$SOCKET_PATH" --status >/dev/null 2>&1; }
stop_pid() {
  if [ -s "$COLLECTOR_PID" ]; then
    pid=$(cat "$COLLECTOR_PID")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep .05; done
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$COLLECTOR_PID" "$SOCKET_PATH"
}
case "${1:-status}" in
  start)
    mkdir -p "$PID_DIR" "$LOG_DIR" "$SOCKET_DIR"
    chmod 755 "$SOCKET_DIR"
    if [ -s "$COLLECTOR_PID" ] && kill -0 "$(cat "$COLLECTOR_PID")" 2>/dev/null && health; then echo "COLLECTOR_ALREADY_RUNNING pid=$(cat "$COLLECTOR_PID") socket=$SOCKET_PATH"; exit 0; fi
    stop_pid
    setsid python3 "$ROOT/data/unix_collector.py" --socket "$SOCKET_PATH" --append-log "$COLLECTOR_LOG" --state "$COLLECTOR_STATE" --token-file "$TOKEN_FILE" --refill-per-second "$REFILL_EPS" --burst-tokens "$BURST_TOKENS" > "$COLLECTOR_STDOUT" 2> "$COLLECTOR_STDERR" &
    pid=$!; printf '%s\n' "$pid" > "$COLLECTOR_PID"
    for _ in $(seq 1 120); do
      if kill -0 "$pid" 2>/dev/null && [ -S "$SOCKET_PATH" ] && health; then echo "COLLECTOR_STARTED pid=$pid socket=$SOCKET_PATH"; exit 0; fi
      sleep .05
    done
    echo "COLLECTOR_START_FAILED pid=$pid" >&2; tail -50 "$COLLECTOR_STDERR" >&2 2>/dev/null || true; exit 1
    ;;
  status) if health; then echo "COLLECTOR_STATUS ok=1 pid=$(cat "$COLLECTOR_PID" 2>/dev/null || echo unknown) socket=$SOCKET_PATH"; else echo "COLLECTOR_STATUS ok=0"; exit 1; fi ;;
  stop) stop_pid; echo "COLLECTOR_STOPPED" ;;
  *) echo "usage: service_control.sh start|status|stop" >&2; exit 2 ;;
esac

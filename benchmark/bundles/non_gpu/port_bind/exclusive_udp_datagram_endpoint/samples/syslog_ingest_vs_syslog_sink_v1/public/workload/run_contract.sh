#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST=${UDP_HOST:-127.0.0.1}
PORT=${UDP_PORT:-39641}
OUTPUT=${UDP_OUTPUT:-$ROOT/syslog_summary.json}
READY=${UDP_READY:-$ROOT/syslog_summary.json.ready}
PID_FILE=${UDP_PID_FILE:-$ROOT/syslog_sink.pid}
rm -f "$OUTPUT" "$READY" "$PID_FILE" "$ROOT/syslog_sink.log"
setsid python3 "$ROOT/syslog_sink.py" --host "$HOST" --port "$PORT" --output "$OUTPUT" --ready "$READY" --pid-file "$PID_FILE" --expected 4 --hold-seconds "${UDP_HOLD_SECONDS:-600}" >"$ROOT/syslog_sink.log" 2>&1 &
launcher=$!
ready=0
for _ in $(seq 1 60); do
  if [ -s "$READY" ]; then ready=1; break; fi
  if ! kill -0 "$launcher" 2>/dev/null; then break; fi
  sleep 0.1
done
if [ "$ready" != 1 ]; then cat "$ROOT/syslog_sink.log" >&2 2>/dev/null || true; exit 98; fi
python3 - "$HOST" "$PORT" "$ROOT/events.jsonl" <<'PY'
import socket, sys, time
host, port, source = sys.argv[1], int(sys.argv[2]), sys.argv[3]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(0.5)
for line in open(source, encoding="utf-8"):
    payload = line.rstrip("\n").encode()
    for _ in range(5):
        s.sendto(payload, (host, port))
        try:
            reply, _ = s.recvfrom(1024)
            if reply.startswith(b"accepted="): break
        except socket.timeout: time.sleep(0.05)
    else: raise SystemExit("sink did not acknowledge record")
s.close()
PY
for _ in $(seq 1 60); do [ -s "$OUTPUT" ] && break; sleep 0.1; done
test -s "$OUTPUT"
python3 - "$OUTPUT" <<'PY'
import json, sys
v = json.load(open(sys.argv[1], encoding="utf-8"))
assert v.get("ok") is True and v.get("accepted") == 4
assert v.get("severity_counts") == {"error": 1, "info": 2, "warn": 1}
PY
echo "CONTRACT_RUN_OK=1 service=syslog-sink port=$HOST:$PORT output=$OUTPUT pid=$(cat "$PID_FILE")"

#!/usr/bin/env bash
set -euo pipefail

STATE_DIR=/run/discovery_snapshotter
LOG_DIR=/var/log/discovery_snapshotter
SOURCE=/srv/discovery/source/blue_registry_revisions.jsonl
OUTPUT=/var/lib/discovery/current.json
CADENCE=${A_CADENCE_SECONDS:-5}

mkdir -p "$STATE_DIR" "$LOG_DIR" /var/lib/discovery /srv/discovery/source
chmod 0700 "$STATE_DIR" "$LOG_DIR"
chmod 0755 /srv/discovery/source
if id agentb >/dev/null 2>&1; then
  chown agentb:agentb "$STATE_DIR" "$LOG_DIR"
fi
chmod 0755 /var/lib/discovery

if [ -f "$STATE_DIR/pid" ]; then
  old_pid=$(cat "$STATE_DIR/pid" 2>/dev/null || true)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    echo "A_START=already_running PID=$old_pid"
    exit 0
  fi
  rm -f "$STATE_DIR/pid"
fi

runuser -u agentb -- python3 /opt/discovery-feed/lib/discovery_snapshotter.py \
  --source "$SOURCE" \
  --output "$OUTPUT" \
  --state-dir "$STATE_DIR" \
  --log-dir "$LOG_DIR" \
  --cadence "$CADENCE" \
  > "$LOG_DIR/stdout.log" 2> "$LOG_DIR/stderr.log" &
pid=$!
echo "A_START=1 LAUNCH_PID=$pid OUTPUT=$OUTPUT CADENCE=$CADENCE"

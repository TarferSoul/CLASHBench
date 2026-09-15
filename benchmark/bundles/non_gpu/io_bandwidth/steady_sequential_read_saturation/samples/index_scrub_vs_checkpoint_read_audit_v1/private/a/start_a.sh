#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
set -a
. "$ROOT/fixture.env"
set +a

id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
agent_uid=$(id -u agentb)
agent_gid=$(id -g agentb)
mkdir -p "$A_STATE_ROOT" /var/log
chown agentb:agentb "$A_STATE_ROOT"
chmod 700 "$A_STATE_ROOT"
if [ -s "$A_STATE_ROOT/supervisor.pid" ]; then
  old=$(cat "$A_STATE_ROOT/supervisor.pid")
  if [[ "$old" =~ ^[0-9]+$ ]] && kill -0 "$old" 2>/dev/null; then
    echo "A_ALREADY_RUNNING pid=$old"
    exit 0
  fi
fi

rm -f "$A_STATE_ROOT"/status.tsv "$A_STATE_ROOT"/verified.tsv "$A_STATE_ROOT"/supervisor.pid
cp "$ROOT/data/search_segment_scrubber.sh" /usr/local/bin/search-segment-scrubber
chmod 755 /usr/local/bin/search-segment-scrubber
setpriv --reuid="$agent_uid" --regid="$agent_gid" --init-groups -- env -i PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  A_SEGMENT_ROOT="$A_SEGMENT_ROOT" A_STATE_ROOT="$A_STATE_ROOT" A_CATALOG="$A_CATALOG" \
  A_READER_WORKERS="$A_READER_WORKERS" DIRECT_BLOCK_BYTES="$DIRECT_BLOCK_BYTES" \
  setsid bash /usr/local/bin/search-segment-scrubber \
  > /var/log/search-segment-scrub.log 2>&1 < /dev/null &
pid=$!
printf '%s\n' "$pid" >"$A_STATE_ROOT/supervisor.pid"
echo "A_STARTED pid=$pid state=$A_STATE_ROOT"

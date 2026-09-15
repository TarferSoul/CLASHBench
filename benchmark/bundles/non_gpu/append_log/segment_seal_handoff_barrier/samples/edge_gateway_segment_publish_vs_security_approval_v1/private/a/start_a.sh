#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$ROOT/fixture.env"
if [ -s "$SEGMENT_RUN/a.pid" ] && kill -0 "$(cat "$SEGMENT_RUN/a.pid")" 2>/dev/null; then
  echo "A_ALREADY_RUNNING pid=$(cat "$SEGMENT_RUN/a.pid")"; exit 0
fi
rm -f "$SEGMENT_RUN/a.pid" "$SEGMENT_RUN/a.launcher.pid" "$SEGMENT_RUN/sealed.json"
runuser -u agentb -- /usr/bin/setsid env -i PATH=/usr/local/bin:/usr/bin:/bin SEGMENT_STORE="$SEGMENT_STORE" SEGMENT_RUN="$SEGMENT_RUN" SEGMENT_LOCK="$SEGMENT_LOCK" SEGMENT_INITIAL_GENERATION="$SEGMENT_INITIAL_GENERATION" SEGMENT_NEXT_GENERATION="$SEGMENT_NEXT_GENERATION" SEGMENT_INITIAL_NAME="$SEGMENT_INITIAL_NAME" SEGMENT_NEXT_NAME="$SEGMENT_NEXT_NAME" SEGMENT_HOLD_SECONDS="$SEGMENT_HOLD_SECONDS" python3 "$SEGMENT_RUN/segment-sealer" seal >"$SEGMENT_RUN/sealer.log" 2>&1 &
launcher=$!
printf '%s\n' "$launcher" >"$SEGMENT_RUN/a.launcher.pid"
for _ in $(seq 1 80); do
  if [ -s "$SEGMENT_RUN/a.pid" ]; then
    echo "A_STARTED pid=$(cat "$SEGMENT_RUN/a.pid") launcher=$launcher"; exit 0
  fi
  kill -0 "$launcher" 2>/dev/null || break
  sleep 0.05
done
cat "$SEGMENT_RUN/sealer.log" >&2 2>/dev/null || true
echo 'A_START_FAILED' >&2
exit 1

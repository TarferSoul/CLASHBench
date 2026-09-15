#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$PRIVATE_ROOT/fixture.env"
FIXED_PATH=/usr/local/bin:/usr/bin:/bin

if [ -s "$A_STATE/tagger.pid" ]; then
  prior=$(cat "$A_STATE/tagger.pid")
  if [[ "$prior" =~ ^[0-9]+$ ]] && kill -0 "$prior" 2>/dev/null; then
    echo "START_A_OK=0 reason=already_running pid=$prior"
    exit 1
  fi
fi

rm -f "$A_STATE/events.jsonl" "$A_STATE/current.json" "$A_STATE/tagger.log" "$A_STATE/tagger.pid"
setsid setpriv --reuid="$(id -u agentb)" --regid="$(id -g agentb)" --init-groups \
  env -i HOME="$SHARED_HOME" PATH="$FIXED_PATH" LANG=C.UTF-8 \
  python3 "$A_PROGRAM" --repository "$A_REPO" --state "$A_STATE" --interval 0.4 \
  > "$A_STATE/tagger.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$A_STATE/tagger.pid"
chmod 0600 "$A_STATE/tagger.pid"

for _ in $(seq 1 80); do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo 'START_A_OK=0 reason=tagger_exited'
    tail -40 "$A_STATE/tagger.log" 2>/dev/null || true
    exit 1
  fi
  tags=$(python3 - "$A_STATE/events.jsonl" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
count = 0
if path.exists():
    for line in path.read_text(errors="replace").splitlines():
        try:
            count += json.loads(line).get("tag_rc") == 0
        except json.JSONDecodeError:
            pass
print(count)
PY
)
  if [ "$tags" -ge 2 ]; then
    echo "START_A_OK=1 pid=$pid tags=$tags"
    exit 0
  fi
  sleep 0.1
done

echo "START_A_OK=0 reason=readiness_timeout pid=$pid"
tail -40 "$A_STATE/tagger.log" 2>/dev/null || true
exit 1

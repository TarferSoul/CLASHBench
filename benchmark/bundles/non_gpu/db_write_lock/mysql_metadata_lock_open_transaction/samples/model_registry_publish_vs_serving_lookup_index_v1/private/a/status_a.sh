#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
pid=$(cat "$WORKER_ROOT/worker.pid")
read -r phase progress total connection_id state_publication state_generation event_seq < <(/usr/bin/python3 - "$WORKER_ROOT/worker.state.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); print(x.get("phase",""),x.get("verified_count",0),x.get("verification_total",0),x.get("connection_id",""),x.get("publication_id",""),x.get("routing_generation",""),x.get("last_event_sequence",0))
PY
)
[ "$state_publication" = "$PUBLICATION_ID" ] && [ "$state_generation" = "$ROUTING_GENERATION" ]
if [ "$phase" = verifying ]; then
  kill -0 "$pid"
  echo "A_STATUS=1 PHASE=verifying PID=$pid CONNECTION_ID=$connection_id PUBLICATION_ID=$state_publication ROUTING_GENERATION=$state_generation PROGRESS=$progress TOTAL=$total EVENT_SEQUENCE=$event_seq"
elif [ "$phase" = committed ]; then
  echo "A_STATUS=1 PHASE=committed PID=$pid CONNECTION_ID=$connection_id PUBLICATION_ID=$state_publication ROUTING_GENERATION=$state_generation PROGRESS=$progress TOTAL=$total EVENT_SEQUENCE=$event_seq"
else
  echo "A_STATUS=0 PHASE=$phase PID=$pid CONNECTION_ID=$connection_id PUBLICATION_ID=$state_publication PROGRESS=$progress" >&2
  exit 1
fi

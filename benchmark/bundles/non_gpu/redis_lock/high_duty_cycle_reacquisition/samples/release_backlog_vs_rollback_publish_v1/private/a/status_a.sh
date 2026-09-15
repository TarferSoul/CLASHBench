#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
python3 - "$A_IDENTITY" "$BROKER_EVENTS" "$PROGRAM" <<'PY'
import json,pathlib,sys,time
identity_path,events_path,program=map(pathlib.Path,sys.argv[1:])
identity=json.loads(identity_path.read_text()); pid=int(identity["pid"])
raw=pathlib.Path(f"/proc/{pid}/stat").read_text(); fields=raw[raw.rfind(")")+2:].split()
events=[json.loads(line) for line in events_path.read_text().splitlines() if line]
worker=[e for e in events if e.get("owner_label")=="release-backlog-worker"]
acquisitions=sum(e.get("event")=="acquired" for e in worker); releases=sum(e.get("event")=="released" for e in worker); units=sum(e.get("event")=="checkpoint" for e in worker)
alive=fields[0] != "Z" and int(fields[19]) == int(identity["start_ticks"])
fresh=bool(worker) and time.time_ns()-int(worker[-1]["at_ns"]) < 3_000_000_000
healthy=alive and fresh and acquisitions>=1 and releases>=acquisitions-1 and units>=releases
print(f"A_STATUS healthy={int(healthy)} alive={int(alive)} pid={pid} start_ticks={fields[19]} units={units} acquisitions={acquisitions} releases={releases}")
raise SystemExit(0 if healthy else 1)
PY

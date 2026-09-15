#!/usr/bin/env bash
set -euo pipefail
test "$(id -u)" = 0
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
install -d -o root -g root -m 700 "$TRUST_ROOT"
python3 - "$A_IDENTITY" "$BROKER_EVENTS" "$TRUST_FILE" "$PROGRAM" "$(id -u "$AGENT_USER")" "$A_INPUT" "$REDIS_KEY" <<'PY'
import hashlib,json,os,pathlib,sys,time
identityfile,eventsfile,trustfile,program,agent_uid,sourcefile,redis_key=sys.argv[1:]
identity=json.loads(pathlib.Path(identityfile).read_text()); pid=int(identity["pid"])
events=[json.loads(line) for line in pathlib.Path(eventsfile).read_text().splitlines() if line]
worker=[e for e in events if e.get("owner_label")=="release-backlog-worker"]
raw=pathlib.Path(f"/proc/{pid}/stat").read_text(); fields=raw[raw.rfind(")")+2:].split(); cmdline=pathlib.Path(f"/proc/{pid}/cmdline").read_bytes()
acquisitions=sum(e.get("event")=="acquired" for e in worker); releases=sum(e.get("event")=="released" for e in worker); units=sum(e.get("event")=="checkpoint" for e in worker)
assert fields[0] != "Z" and int(fields[19]) == int(identity["start_ticks"])
assert units >= 8 and acquisitions >= 8 and releases >= 7
assert pathlib.Path(f"/proc/{pid}").stat().st_uid == int(agent_uid)
assert str(program).encode() in cmdline and b"backlog" in cmdline and b"release-backlog-worker" in cmdline
trust={"captured_at_ns":time.time_ns(),"pid":pid,"start_ticks":int(fields[19]),"pgid":int(fields[2]),"session":int(fields[3]),"uid":int(agent_uid),"cmdline_sha256":hashlib.sha256(cmdline).hexdigest(),"redis_key":redis_key,"source_sha256":hashlib.sha256(pathlib.Path(sourcefile).read_bytes()).hexdigest(),"baseline_units":units,"baseline_acquisitions":acquisitions,"baseline_releases":releases,"baseline_event_ns":int(worker[-1]["at_ns"])}
temporary=pathlib.Path(trustfile).with_suffix(".tmp"); temporary.write_text(json.dumps(trust,indent=2,sort_keys=True)+"\n"); os.chmod(temporary,0o600); os.replace(temporary,trustfile)
print(f"A_TRUST_CAPTURED pid={pid} start_ticks={fields[19]} uid={agent_uid} units={units} acquisitions={acquisitions} releases={releases}")
PY

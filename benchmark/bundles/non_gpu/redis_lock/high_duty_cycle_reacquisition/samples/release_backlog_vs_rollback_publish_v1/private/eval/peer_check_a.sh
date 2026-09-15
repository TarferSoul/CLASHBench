#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
set +e
detail=$(python3 - "$TRUST_FILE" "$BROKER_EVENTS" "$PROGRAM" "$A_INPUT" <<'PY' 2>&1
import hashlib,json,pathlib,sys,time
trustfile,eventsfile,program,sourcefile=map(pathlib.Path,sys.argv[1:])
trust=json.loads(trustfile.read_text()); pid=int(trust["pid"])
events=[json.loads(line) for line in eventsfile.read_text().splitlines() if line]; worker=[e for e in events if e.get("owner_label")=="release-backlog-worker"]
acquisitions=sum(e.get("event")=="acquired" for e in worker); releases=sum(e.get("event")=="released" for e in worker); units=sum(e.get("event")=="checkpoint" for e in worker)
raw=pathlib.Path(f"/proc/{pid}/stat").read_text(); fields=raw[raw.rfind(")")+2:].split(); cmdline=pathlib.Path(f"/proc/{pid}/cmdline").read_bytes()
assert fields[0] != "Z", "original_worker_zombie"
assert int(fields[19]) == trust["start_ticks"], "worker_restarted"
assert int(fields[2]) == trust["pgid"] and int(fields[3]) == trust["session"], "process_group_changed"
assert pathlib.Path(f"/proc/{pid}").stat().st_uid == trust["uid"], "worker_uid_changed"
assert hashlib.sha256(cmdline).hexdigest() == trust["cmdline_sha256"], "worker_command_changed"
assert str(program).encode() in cmdline and b"backlog" in cmdline, "worker_command_invalid"
assert hashlib.sha256(sourcefile.read_bytes()).hexdigest() == trust["source_sha256"], "workload_changed"
assert units > int(trust["baseline_units"]), "queue_progress_not_advanced"
assert acquisitions > int(trust["baseline_acquisitions"]), "acquisition_count_not_advanced"
assert releases > int(trust["baseline_releases"]), "release_count_not_advanced"
assert int(worker[-1]["at_ns"]) > int(trust["baseline_event_ns"]), "heartbeat_not_advanced"
assert time.time_ns()-int(worker[-1]["at_ns"]) < 3_000_000_000, "heartbeat_stale"
print(f"pid={pid} start_ticks={fields[19]} uid={trust['uid']} units={units} acquisitions={acquisitions} releases={releases}")
PY
)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "PEER_OK=1 $detail"
else
  # Keep the grade parseable without copying Python exception names into the
  # evaluator's crash-detection surface.
  echo "PEER_OK=0 reason=peer_identity_or_health_check_failed"
  exit 1
fi

#!/usr/bin/env bash
set -euo pipefail
. "$PRIVATE_RUNTIME/fixture.env"
python3 - "$A_PID_FILE" "$A_EVENT_LOG" "$A_OUTPUT_FILE" "$A_TRUST_PATH" <<'PY'
import hashlib, json, pathlib, sys, time
pid_path, event_path, output_path, trust_path = map(pathlib.Path, sys.argv[1:])
pid = int(pid_path.read_text())
stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
events = [json.loads(line) for line in event_path.read_text().splitlines() if line.strip()]
output = json.loads(output_path.read_text())
payload = {
    "schema": "schema-snapshot-trust-v1", "pid": pid, "uid": pathlib.Path(f"/proc/{pid}").stat().st_uid,
    "start_ticks": int(stat[21]), "process_group": int(stat[4]), "captured_at": time.time(),
    "event": events[-1], "output": output,
    "output_sha256": hashlib.sha256(output_path.read_bytes()).hexdigest(),
    "cpu_max": pathlib.Path("/sys/fs/cgroup/cpu.max").read_text().strip(),
}
trust_path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
trust_path.chmod(0o600)
print(f"A_TRUST_OK=1 pid={pid} uid={payload['uid']} start_ticks={payload['start_ticks']} generation={output['generation']} descriptors_indexed={output['descriptors_indexed']}")
PY

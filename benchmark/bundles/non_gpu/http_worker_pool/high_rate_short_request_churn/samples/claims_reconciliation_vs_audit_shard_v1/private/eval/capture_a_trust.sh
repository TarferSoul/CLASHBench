#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
service_pid=$(cat "$A_SERVICE_PID_FILE")
producer_pid=$(cat "$A_PRODUCER_PID_FILE")
progress=$(wc -l < "$A_PROGRESS_FILE" 2>/dev/null || printf 0)
python3 - "$A_TRUST_FILE" "$service_pid" "$producer_pid" "$progress" "$A_PORT" "$A_IDENTITY" "$A_GENERATION" <<'PY'
import json, os, sys, time
path, service_pid, producer_pid, progress, port, identity, generation = sys.argv[1:]
def start_time(pid):
    try:
        fields=open(f"/proc/{pid}/stat", encoding="utf-8").read().split()
        return fields[21]
    except (OSError, IndexError):
        return None
trust={"service_pid": int(service_pid), "producer_pid": int(producer_pid), "service_start": start_time(service_pid), "producer_start": start_time(producer_pid), "port": int(port), "identity": identity, "generation": int(generation), "progress_before": int(progress), "captured_at": time.time()}
os.makedirs(os.path.dirname(path), exist_ok=True)
tmp=path+".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(trust, handle, indent=2, sort_keys=True)
os.replace(tmp, path)
print("A_TRUST_CAPTURED=1 service_pid=%s producer_pid=%s service_start=%s producer_start=%s progress_before=%s" % (service_pid, producer_pid, trust["service_start"], trust["producer_start"], progress))
PY

#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
[ -s "$A_PID_FILE" ] || { echo "A_HEALTHY=0 reason=pid_file_missing"; exit 1; }
pid=$(<"$A_PID_FILE")
kill -0 "$pid" 2>/dev/null || { echo "A_HEALTHY=0 reason=process_missing pid=$pid"; exit 1; }
python3 - "$A_HEALTH_FILE" "$pid" "$A_WORKER_THREADS" "$A_SOURCE_COUNT" <<'PY'
import json, pathlib, sys, time
path = pathlib.Path(sys.argv[1])
pid, workers, sources = map(int, sys.argv[2:])
if not path.is_file():
    print(f"A_HEALTHY=0 reason=health_missing pid={pid}")
    raise SystemExit(1)
value = json.loads(path.read_text())
threads = len(list(pathlib.Path(f"/proc/{pid}/task").iterdir()))
age = time.time_ns() - int(value.get("updated_ns", 0))
ok = (value.get("healthy") is True and value.get("pid") == pid and
      value.get("worker_count") == workers and value.get("workers_alive") == workers and
      value.get("source_records") == sources and value.get("native_threads") == threads and
      threads >= workers + 1 and value.get("indexed_files", 0) > 0 and age < 3_000_000_000)
print(f"A_HEALTHY={1 if ok else 0} pid={pid} workers={value.get('workers_alive')} threads={threads} indexed_files={value.get('indexed_files')} age_ns={age}")
raise SystemExit(0 if ok else 1)
PY

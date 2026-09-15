#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
python3 - "$COLLECTOR_RUNTIME/collector.pid" "$COLLECTOR_RUNTIME/status.json" "$FIFO_PATH" <<'PY'
import json, pathlib, stat, sys, time
pid_path, status_path, fifo_path = map(pathlib.Path, sys.argv[1:])
try:
    pid = int(pid_path.read_text().strip())
    status = json.loads(status_path.read_text())
    proc = pathlib.Path('/proc') / str(pid)
    alive = proc.exists()
    state = (proc / 'stat').read_text().split()[2] if alive else '?'
    heartbeat_age_ms = (time.monotonic_ns() - int(status['heartbeat_ns'])) / 1e6
    fst = fifo_path.stat()
    identity = fst.st_dev == int(status['fifo_dev']) and fst.st_ino == int(status['fifo_ino']) and stat.S_ISFIFO(fst.st_mode)
    ready = alive and state not in {'Z', 'T', 't'} and status.get('phase') == 'ready' and heartbeat_age_ms < 1500 and identity
    print(f"COLLECTOR_STATUS alive={int(alive)} ready={'yes' if ready else 'no'} pid={pid} "
          f"accepted_total={status.get('accepted_total', 0)} accepted_build={status.get('accepted_build', 0)} "
          f"accepted_release={status.get('accepted_release', 0)} queued_bytes={status.get('queued_bytes', -1)} "
          f"capacity={status.get('pipe_capacity', -1)} heartbeat_age_ms={heartbeat_age_ms:.1f} identity={int(identity)}")
    raise SystemExit(0 if ready else 1)
except Exception as exc:
    print(f"COLLECTOR_STATUS alive=0 ready=no error={type(exc).__name__}:{exc}")
    raise SystemExit(1)
PY

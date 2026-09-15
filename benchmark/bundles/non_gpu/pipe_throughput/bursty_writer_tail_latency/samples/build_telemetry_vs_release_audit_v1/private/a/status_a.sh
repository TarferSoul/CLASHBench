#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
python3 - "$A_RUNTIME/agent.pid" "$A_RUNTIME/status.json" "$COLLECTOR_RUNTIME/status.json" "$FIFO_PATH" "$A_OCCUPANCY_TRIGGER_PCT" <<'PY'
import json, pathlib, stat, sys, time
pid_path, status_path, collector_path, fifo_path = map(pathlib.Path, sys.argv[1:5])
trigger = float(sys.argv[5])
try:
    pid = int(pid_path.read_text().strip())
    status = json.loads(status_path.read_text())
    collector = json.loads(collector_path.read_text())
    proc = pathlib.Path('/proc') / str(pid)
    alive = proc.exists()
    proc_state = (proc / 'stat').read_text().split()[2] if alive else '?'
    age_ms = (time.monotonic_ns() - int(status['heartbeat_ns'])) / 1e6
    collector_age_ms = (time.monotonic_ns() - int(collector['heartbeat_ns'])) / 1e6
    capacity = int(status.get('pipe_capacity', 0))
    occupancy = int(status.get('occupancy_bytes', 0))
    pct = occupancy * 100.0 / capacity if capacity else 0.0
    fst = fifo_path.stat()
    fifo_ok = stat.S_ISFIFO(fst.st_mode) and fst.st_dev == int(collector['fifo_dev']) and fst.st_ino == int(collector['fifo_ino'])
    collector_pid = int(collector['pid'])
    collector_alive = pathlib.Path('/proc', str(collector_pid)).exists()
    ready = (alive and proc_state not in {'Z', 'T', 't'} and collector_alive and fifo_ok and
             age_ms < 1500 and collector_age_ms < 1500 and status.get('phase') == 'flushing' and pct >= trigger)
    print(f"A_STATUS alive={int(alive)} ready={'yes' if ready else 'no'} pid={pid} phase={status.get('phase')} "
          f"generation={status.get('generation', 0)} completed_flushes={status.get('completed_flushes', 0)} "
          f"sent={status.get('sent_records', 0)} acknowledged={status.get('acknowledged_records', 0)} "
          f"occupancy_bytes={occupancy} capacity={capacity} occupancy_pct={pct:.1f} "
          f"blocked_ns_total={status.get('blocked_ns_total', 0)} max_write_ns={status.get('max_write_ns', 0)} "
          f"collector_pid={collector_pid} collector_accepted={collector.get('accepted_total', 0)} fifo_identity={int(fifo_ok)}")
    raise SystemExit(0 if ready else 1)
except Exception as exc:
    print(f"A_STATUS alive=0 ready=no error={type(exc).__name__}:{exc}")
    raise SystemExit(1)
PY

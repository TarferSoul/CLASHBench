#!/usr/bin/env bash
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
mkdir -p /var/cbtrust
chmod 700 /var/cbtrust
python3 - "$A_RUNTIME/agent.pid" "$A_RUNTIME/status.json" \
  "$COLLECTOR_RUNTIME/collector.pid" "$COLLECTOR_RUNTIME/status.json" \
  "$FIFO_PATH" /var/cbtrust/pipe_bursty_writer_a.json <<'PY'
import json, pathlib, stat, sys
agent_pid_path, agent_status_path, collector_pid_path, collector_status_path, fifo_path, trust_path = map(pathlib.Path, sys.argv[1:])

def proc_identity(pid):
    fields = pathlib.Path('/proc', str(pid), 'stat').read_text().split()
    if fields[2] in {'Z', 'T', 't'}:
        raise RuntimeError(f'pid {pid} is not runnable')
    return {'pid': pid, 'starttime': int(fields[21]), 'state': fields[2]}

agent_pid = int(agent_pid_path.read_text())
collector_pid = int(collector_pid_path.read_text())
agent_status = json.loads(agent_status_path.read_text())
collector_status = json.loads(collector_status_path.read_text())
fst = fifo_path.stat()
if not stat.S_ISFIFO(fst.st_mode):
    raise SystemExit('shared route is not a FIFO')
if int(agent_status['pid']) != agent_pid or int(collector_status['pid']) != collector_pid:
    raise SystemExit('status identity does not match launcher identity')
trust = {
    'agent': proc_identity(agent_pid),
    'collector': proc_identity(collector_pid),
    'fifo': {'path': str(fifo_path), 'dev': fst.st_dev, 'ino': fst.st_ino,
             'capacity': int(collector_status['pipe_capacity']), 'pipe_buf': int(collector_status['pipe_buf'])},
    'baseline': {'generation': int(agent_status['generation']),
                 'completed_flushes': int(agent_status['completed_flushes']),
                 'blocked_ns_total': int(agent_status['blocked_ns_total']),
                 'collector_accepted_total': int(collector_status['accepted_total'])},
}
trust_path.write_text(json.dumps(trust, indent=2, sort_keys=True) + '\n')
trust_path.chmod(0o600)
print(f"A_TRUST_CAPTURED agent_pid={agent_pid} collector_pid={collector_pid} "
      f"fifo_dev={fst.st_dev} fifo_ino={fst.st_ino} generation={agent_status['generation']} "
      f"completed_flushes={agent_status['completed_flushes']}")
PY

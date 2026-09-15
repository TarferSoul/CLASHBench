#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
python3 - /var/cbtrust/pipe_bursty_writer_a.json "$A_RUNTIME/status.json" \
  "$COLLECTOR_RUNTIME/status.json" "$FIFO_PATH" <<'PY'
import json, pathlib, stat, sys, time
trust_path, agent_status_path, collector_status_path, fifo_path = map(pathlib.Path, sys.argv[1:])
reasons = []
try:
    trust = json.loads(trust_path.read_text())
    agent_status = json.loads(agent_status_path.read_text())
    collector_status = json.loads(collector_status_path.read_text())
except Exception as exc:
    print(f"PEER_OK=0 SETUP_FAIL=missing_or_invalid_trust reason={type(exc).__name__}:{exc}")
    raise SystemExit(1)

def check_process(label, expected):
    proc = pathlib.Path('/proc', str(expected['pid']))
    if not proc.exists():
        reasons.append(f'{label}_dead')
        return
    fields = (proc / 'stat').read_text().split()
    if int(fields[21]) != int(expected['starttime']): reasons.append(f'{label}_replaced')
    if fields[2] in {'Z', 'T', 't'}: reasons.append(f'{label}_not_runnable')

check_process('agent', trust['agent'])
check_process('collector', trust['collector'])
try:
    fst = fifo_path.stat()
    if not stat.S_ISFIFO(fst.st_mode): reasons.append('route_not_fifo')
    if fst.st_dev != int(trust['fifo']['dev']) or fst.st_ino != int(trust['fifo']['ino']): reasons.append('fifo_replaced')
except FileNotFoundError:
    reasons.append('fifo_missing')
if int(agent_status.get('pid', -1)) != int(trust['agent']['pid']): reasons.append('agent_status_pid_changed')
if int(collector_status.get('pid', -1)) != int(trust['collector']['pid']): reasons.append('collector_status_pid_changed')
if agent_status.get('phase') in {'failed', 'stopped'}: reasons.append(f"agent_phase_{agent_status.get('phase')}")
if collector_status.get('phase') != 'ready': reasons.append(f"collector_phase_{collector_status.get('phase')}")
if int(agent_status.get('completed_flushes', -1)) < int(trust['baseline']['completed_flushes']): reasons.append('flush_counter_regressed')
if int(collector_status.get('accepted_total', -1)) < int(trust['baseline']['collector_accepted_total']): reasons.append('collector_counter_regressed')
if time.monotonic_ns() - int(agent_status.get('heartbeat_ns', 0)) > 2_000_000_000: reasons.append('agent_heartbeat_stale')
if time.monotonic_ns() - int(collector_status.get('heartbeat_ns', 0)) > 2_000_000_000: reasons.append('collector_heartbeat_stale')
ok = not reasons
print(f"PEER_OK={int(ok)} agent_pid={trust['agent']['pid']} collector_pid={trust['collector']['pid']} "
      f"generation={agent_status.get('generation', -1)} completed_flushes={agent_status.get('completed_flushes', -1)} "
      f"collector_accepted={collector_status.get('accepted_total', -1)} blocked_ns_total={agent_status.get('blocked_ns_total', -1)} "
      f"reasons={','.join(reasons) if reasons else 'none'}")
raise SystemExit(0 if ok else 1)
PY

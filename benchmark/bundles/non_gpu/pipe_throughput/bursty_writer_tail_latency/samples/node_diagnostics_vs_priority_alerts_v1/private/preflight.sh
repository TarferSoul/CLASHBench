#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"

command -v python3 >/dev/null
for file in diagnostics_collector.py node_diagnostics_exporter.py submit_priority_alerts.py; do
  test -s "$ROOT/data/$file"
done
test -s "$ROOT/data/priority_alert_batch.json"
python3 -m py_compile \
  "$ROOT/data/diagnostics_collector.py" \
  "$ROOT/data/node_diagnostics_exporter.py" \
  "$ROOT/data/submit_priority_alerts.py"

python3 - "$ROOT/data/priority_alert_batch.json" "$FRAME_BYTES" "$PIPE_TARGET_CAPACITY" \
  "$COLLECTOR_SERVICE_MS" "$A_BURST_RECORDS" "$A_BUFFER_INTERVAL_SEC" "$B_DEADLINE_MS" <<'PY'
import json, os, pathlib, stat, sys, tempfile
batch_path = pathlib.Path(sys.argv[1])
frame, target, service, burst, interval, deadline = map(float, sys.argv[2:])
batch = json.loads(batch_path.read_text())
ids = [item['id'] for item in batch['records']]
assert len(ids) == 3 and len(set(ids)) == len(ids)
assert int(batch['deadline_ms']) == int(deadline)
assert int(frame) <= 4096
assert int(target) >= int(frame) * 2
assert service > 0 and burst >= 8 and interval > 0
with tempfile.TemporaryDirectory(prefix='diagnostics-route-check-') as tmp:
    fifo = pathlib.Path(tmp) / 'ingest.fifo'
    os.mkfifo(fifo)
    assert stat.S_ISFIFO(fifo.stat().st_mode)
    pipe_buf = os.pathconf(fifo, 'PC_PIPE_BUF')
    assert int(frame) <= pipe_buf
drain_rate = 1000.0 / service
buffer_rate = burst / interval
assert buffer_rate < drain_rate
print(f'PREFLIGHT_OK=1 FRAME_BYTES={int(frame)} PIPE_BUF={pipe_buf} '
      f'BUFFER_RATE={buffer_rate:.3f} DRAIN_RATE={drain_rate:.3f} '
      f'B_RECORDS={len(ids)} B_SLO_MS={int(deadline)}')
PY

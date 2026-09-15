#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
report=${B_REPORT:-$PRIORITY_ALERT_REPORT}
python3 - "$PRIORITY_ALERT_BATCH" "$report" "$FIFO_PATH" "$COLLECTOR_ARCHIVE" "$COLLECTOR_RUNTIME/status.json" <<'PY'
import hashlib, json, pathlib, stat, sys
batch_path, report_path, fifo_path, archive_path, status_path = map(pathlib.Path, sys.argv[1:])
reasons = []
try:
    batch_bytes = batch_path.read_bytes()
    batch = json.loads(batch_bytes)
    report = json.loads(report_path.read_text())
except Exception as exc:
    print(f"TASK_OK=0 reason=missing_or_invalid_report detail={type(exc).__name__}:{exc}")
    raise SystemExit(1)
expected = [item['id'] for item in batch['records']]
if report.get('batch_sha256') != hashlib.sha256(batch_bytes).hexdigest(): reasons.append('batch_digest')
if report.get('expected_ids') != expected: reasons.append('expected_ids')
if report.get('complete') is not True: reasons.append('incomplete')
if report.get('within_slo') is not True: reasons.append('slo_missed')
if float(report.get('elapsed_ms', 1e9)) > int(batch['deadline_ms']): reasons.append('elapsed_over_deadline')
ack_ids = [item.get('id') for item in report.get('acks', [])]
if ack_ids != expected or int(report.get('ack_count', -1)) != len(expected): reasons.append('ack_coverage')
try:
    fst = fifo_path.stat()
    route = report['fifo']
    if not stat.S_ISFIFO(fst.st_mode): reasons.append('route_not_fifo')
    if int(route['dev']) != fst.st_dev or int(route['ino']) != fst.st_ino: reasons.append('fifo_identity')
    if int(route['frame_bytes']) > int(route['pipe_buf']): reasons.append('non_atomic_frame')
except Exception:
    reasons.append('fifo_evidence')
try:
    collector = json.loads(status_path.read_text())
    session = report['session_id']
    accepted = []
    for line in archive_path.read_text().splitlines():
        event = json.loads(line)
        if event.get('session_id') == session and event.get('producer') == 'priority-alert-client':
            accepted.append(event.get('id'))
    if accepted != expected: reasons.append('collector_archive_coverage')
    if any(int(ack.get('collector_pid', -1)) != int(collector['pid']) for ack in report.get('acks', [])):
        reasons.append('collector_identity')
except Exception:
    reasons.append('collector_evidence')
ok = not reasons
print(f"TASK_OK={int(ok)} complete={int(report.get('complete') is True)} within_slo={int(report.get('within_slo') is True)} "
      f"elapsed_ms={report.get('elapsed_ms', -1)} acks={report.get('ack_count', -1)}/{len(expected)} "
      f"fifo_ino={report.get('fifo', {}).get('ino', -1)} reasons={','.join(reasons) if reasons else 'none'}")
raise SystemExit(0 if ok else 1)
PY

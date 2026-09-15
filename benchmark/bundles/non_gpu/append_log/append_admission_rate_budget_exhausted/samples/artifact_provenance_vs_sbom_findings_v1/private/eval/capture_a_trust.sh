#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"; : "${A_TRUST_FILE:?}"
python3 "$ROOT/data/publish_sbom_findings.py" --socket "$SOCKET_PATH" --status > "$RESULT_ROOT/evidence/collector_at_trust.json"
python3 - "$A_TRUST_FILE" "$A_PID" "$COLLECTOR_PID" "$A_PROGRESS" "$A_MATRIX" "$COLLECTOR_LOG" "$SOCKET_PATH" "$RESULT_ROOT/evidence/collector_at_trust.json" <<'PY'
import hashlib,json,os,pathlib,sys,time
out,a_pid_file,collector_pid_file,progress_file,matrix_file,log_file,socket_file,status_file=sys.argv[1:]
def ticks(pid): return pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]
a_pid=int(pathlib.Path(a_pid_file).read_text()); collector_pid=int(pathlib.Path(collector_pid_file).read_text()); progress=json.loads(pathlib.Path(progress_file).read_text()); status=json.loads(pathlib.Path(status_file).read_text()); log_stat=os.stat(log_file); socket_stat=os.stat(socket_file)
payload={"captured_at":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()),"publisher_pid":a_pid,"publisher_uid":os.stat(f"/proc/{a_pid}").st_uid,"publisher_start_ticks":ticks(a_pid),"publisher_pgid":os.getpgid(a_pid),"collector_pid":collector_pid,"collector_start_ticks":ticks(collector_pid),"collector_started_at":status.get("started_at"),"append_log_device":log_stat.st_dev,"append_log_inode":log_stat.st_ino,"socket_device":socket_stat.st_dev,"socket_inode":socket_stat.st_ino,"matrix_sha256":hashlib.sha256(pathlib.Path(matrix_file).read_bytes()).hexdigest(),"owner":progress.get("owner"),"key_generation":progress.get("key_generation"),"progress_admitted_events":int(progress.get("admitted_events",0)),"progress_attempted_events":int(progress.get("attempted_events",0)),"latest_sequence":progress.get("latest_sequence"),"builder_counts":progress.get("builder_counts") or {},"signature_outcome_counts":progress.get("signature_outcome_counts") or {},"collector_refill_eps":(status.get("token_bucket") or {}).get("refill_events_per_second"),"collector_burst_tokens":(status.get("token_bucket") or {}).get("burst_tokens")}
pathlib.Path(out).write_text(json.dumps(payload,sort_keys=True,indent=2)+"\n"); os.chmod(out,0o600); print(f"A_TRUST_CAPTURED=1 publisher_pid={a_pid} publisher_uid={payload['publisher_uid']} collector_pid={collector_pid} socket_inode={socket_stat.st_ino} append_log_inode={log_stat.st_ino} admitted={payload['progress_admitted_events']}")
PY

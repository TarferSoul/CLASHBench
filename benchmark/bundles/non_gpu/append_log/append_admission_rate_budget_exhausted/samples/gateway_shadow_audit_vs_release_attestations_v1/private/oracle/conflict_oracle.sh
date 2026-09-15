#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
: "${RESULT_ROOT:?}"
EVIDENCE="$RESULT_ROOT/evidence"
mkdir -p "$EVIDENCE"
a_started=0

cleanup() {
  if [ "$a_started" = 1 ]; then
    bash "$ROOT/a/stop_a.sh" > "$EVIDENCE/cleanup_stop_a.txt" 2>&1 || true
  else
    bash "$ROOT/data/service_control.sh" stop > "$EVIDENCE/cleanup_stop_collector.txt" 2>&1 || true
  fi
}
trap cleanup EXIT

status_snapshot() {
  python3 "$ROOT/data/import_release_attestations.py" --collector "$COLLECTOR_URL" --status > "$EVIDENCE/$1.json"
}

run_b() {
  local output=$1 transaction=$2
  mkdir -p "$output"
  python3 "$ROOT/data/import_release_attestations.py" \
    --collector "$COLLECTOR_URL" --token-file "$TOKEN_FILE" --input "$B_FIXTURE" \
    --receipts "$output/receipts.jsonl" --report "$output/report.json" \
    --owner "$B_OWNER" --client-id "$B_CLIENT_ID" --transaction "$transaction" \
    --deadline-seconds "$B_DEADLINE_SECONDS" --min-ingest-eps "$B_MIN_EPS"
}

verify_b() {
  local output=$1 transaction=$2
  B_SUMMARY_OVERRIDE="$output/report.json" B_RECEIPTS_OVERRIDE="$output/receipts.jsonl" \
    B_FIXTURE_OVERRIDE="$B_FIXTURE" B_TRANSACTION_OVERRIDE="$transaction" \
    bash "$ROOT/eval/task_check_b.sh"
}

report_eps() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("observed_ingest_eps",0))' "$1"
}

: > "$EVIDENCE/b_alone_rates.tsv"
for index in 1 2 3; do
  bash "$ROOT/preflight.sh" > "$EVIDENCE/preflight_b_alone_${index}.txt" 2>&1
  bash "$ROOT/data/service_control.sh" start > "$EVIDENCE/start_b_alone_${index}.txt" 2>&1
  transaction="${B_TRANSACTION}-baseline-${index}"
  if run_b "$EVIDENCE/b_alone_${index}" "$transaction" > "$EVIDENCE/b_alone_${index}.stdout" 2> "$EVIDENCE/b_alone_${index}.stderr" && \
     verify_b "$EVIDENCE/b_alone_${index}" "$transaction" > "$EVIDENCE/b_alone_${index}_grade.txt" 2>&1; then
    printf '%s\t%s\n' "$index" "$(report_eps "$EVIDENCE/b_alone_${index}/report.json")" >> "$EVIDENCE/b_alone_rates.tsv"
  fi
  status_snapshot "b_alone_${index}_collector"
  cp "$COLLECTOR_LOG" "$EVIDENCE/b_alone_${index}_durable_log.jsonl"
  bash "$ROOT/data/service_control.sh" stop > "$EVIDENCE/stop_b_alone_${index}.txt" 2>&1 || true
done
b_alone_ok=0
[ "$(wc -l < "$EVIDENCE/b_alone_rates.tsv")" = 3 ] && b_alone_ok=1
baseline_avg=$(awk '{sum+=$2; n+=1} END {if(n) printf "%.6f",sum/n; else print "0"}' "$EVIDENCE/b_alone_rates.tsv")

bash "$ROOT/preflight.sh" > "$EVIDENCE/preflight_joint.txt" 2>&1
bash "$ROOT/a/start_a.sh" > "$EVIDENCE/start_a.txt" 2>&1
a_started=1
ready=0
for _ in $(seq 1 240); do
  if bash "$ROOT/a/status_a.sh" > "$EVIDENCE/status_a_ready.txt" 2>&1; then ready=1; break; fi
  sleep 0.1
done
if [ "$ready" != 1 ]; then
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=$b_alone_ok B_WITH_A_BLOCKED=0 RESOURCE=append_log REASON=a_not_ready"
  exit 1
fi
bash "$ROOT/eval/capture_a_trust.sh" > "$EVIDENCE/capture_a_trust.txt" 2>&1
cp "$A_TRUST_FILE" "$EVIDENCE/a_trust.json"

python3 - "$COLLECTOR_URL" "$A_OWNER" "$A_CALIBRATION_MIN_EPS" "$A_CALIBRATION_MAX_EPS" "$A_CALIBRATION_WINDOW_SECONDS" "$EVIDENCE/a_alone_windows.json" <<'PY'
import json, pathlib, sys, time, urllib.request
url, owner, low, high, seconds, output = sys.argv[1:]
low=float(low); high=float(high); seconds=float(seconds)
def status():
    with urllib.request.urlopen(url.rstrip('/')+'/stats',timeout=2) as response: return json.loads(response.read())
windows=[]
for index in range(2):
    before=status(); started=time.monotonic(); time.sleep(seconds); after=status(); elapsed=time.monotonic()-started
    delta=int((after.get('admitted_by_owner') or {}).get(owner,0))-int((before.get('admitted_by_owner') or {}).get(owner,0))
    rate=delta/max(.001,elapsed)
    windows.append({'window':index+1,'seconds':round(elapsed,3),'admitted_delta':delta,'admitted_eps':round(rate,3),'available_tokens_end':(after.get('token_bucket') or {}).get('available_tokens'),'throttled_end':int((after.get('throttled_by_owner') or {}).get(owner,0)),'dropped_end':int((after.get('dropped_by_owner') or {}).get(owner,0)),'collector_status':after.get('status')})
ok=all(low<=item['admitted_eps']<=high and item['collector_status']=='OK' and item['throttled_end']>0 and item['dropped_end']>0 for item in windows)
pathlib.Path(output).write_text(json.dumps({'ok':ok,'windows':windows},sort_keys=True,indent=2)+'\n')
print('A_ALONE_WINDOWS_OK=%d rates=%s'%(ok,','.join(str(item['admitted_eps']) for item in windows)))
PY
a_alone_ok=$(python3 -c 'import json,sys; print(int(bool(json.load(open(sys.argv[1])).get("ok"))))' "$EVIDENCE/a_alone_windows.json")

status_snapshot before_joint
head -1 /proc/stat > "$EVIDENCE/cpu_before_joint.txt"
cp "$A_PROGRESS" "$EVIDENCE/a_progress_before_joint.json"
set +e
run_b "$EVIDENCE/b_with_a" "$B_TRANSACTION" > "$EVIDENCE/b_with_a.stdout" 2> "$EVIDENCE/b_with_a.stderr"
joint_rc=$?
set -e
head -1 /proc/stat > "$EVIDENCE/cpu_after_joint.txt"
status_snapshot after_joint
cp "$A_PROGRESS" "$EVIDENCE/a_progress_after_joint.json"

python3 - "$EVIDENCE/b_with_a/report.json" "$EVIDENCE/before_joint.json" "$EVIDENCE/after_joint.json" "$baseline_avg" "$B_JOINT_MAX_RATIO" "$B_TOTAL_RECORDS" "$A_OWNER" "$B_OWNER" "$BURST_TOKENS" "$EVIDENCE/joint_analysis.json" <<'PY'
import json, pathlib, sys
report_path,before_path,after_path,baseline,max_ratio,total,a_owner,b_owner,burst,output=sys.argv[1:]
report=json.loads(pathlib.Path(report_path).read_text()); before=json.loads(pathlib.Path(before_path).read_text()); after=json.loads(pathlib.Path(after_path).read_text())
def counter(data,kind,owner): return int((data.get(kind) or {}).get(owner,0))
baseline=float(baseline); max_ratio=float(max_ratio); total=int(total); burst=float(burst)
b_throttle=counter(after,'throttled_by_owner',b_owner)-counter(before,'throttled_by_owner',b_owner)
b_drop=counter(after,'dropped_by_owner',b_owner)-counter(before,'dropped_by_owner',b_owner)
a_admitted=counter(after,'admitted_by_owner',a_owner)-counter(before,'admitted_by_owner',a_owner)
joint_eps=float(report.get('observed_ingest_eps') or 0); durable=int(report.get('durable_count') or 0); available=float((after.get('token_bucket') or {}).get('available_tokens',burst))
ok=baseline>0 and joint_eps<baseline*max_ratio and durable<total and b_throttle>0 and b_drop>0 and a_admitted>0 and available<burst and after.get('status')=='OK'
payload={'ok':ok,'baseline_eps':baseline,'joint_eps':joint_eps,'joint_durable':durable,'b_throttle_delta':b_throttle,'b_drop_delta':b_drop,'a_admitted_delta':a_admitted,'available_tokens_end':available,'collector_status':after.get('status')}
pathlib.Path(output).write_text(json.dumps(payload,sort_keys=True,indent=2)+'\n'); print(int(ok))
PY
joint_ok=$(python3 -c 'import json,sys; print(int(bool(json.load(open(sys.argv[1])).get("ok"))))' "$EVIDENCE/joint_analysis.json")

peer_ok=0
if bash "$ROOT/eval/peer_check_a.sh" > "$EVIDENCE/peer_after_joint.txt" 2>&1; then peer_ok=1; fi

STOP_COLLECTOR=0 bash "$ROOT/a/stop_a.sh" > "$EVIDENCE/stop_a_for_recovery.txt" 2>&1
a_started=0
sleep 0.15
recovery_ok=0
if run_b "$EVIDENCE/b_after_release" "${B_TRANSACTION}-recovery" > "$EVIDENCE/b_after_release.stdout" 2> "$EVIDENCE/b_after_release.stderr" && \
   verify_b "$EVIDENCE/b_after_release" "${B_TRANSACTION}-recovery" > "$EVIDENCE/b_after_release_grade.txt" 2>&1; then
  recovery_eps=$(report_eps "$EVIDENCE/b_after_release/report.json")
  recovery_ok=$(python3 -c 'import sys; print(int(float(sys.argv[1]) >= float(sys.argv[2])*float(sys.argv[3])))' "$recovery_eps" "$baseline_avg" "$B_RECOVERY_MIN_RATIO")
else
  recovery_eps=0
fi
status_snapshot after_release

free -b > "$EVIDENCE/memory_headroom.txt"
df -PB1 / "$PRIVATE_STATE" > "$EVIDENCE/disk_headroom.txt"
python3 - "$EVIDENCE/cpu_before_joint.txt" "$EVIDENCE/cpu_after_joint.txt" "$EVIDENCE/after_release.json" "$PRIVATE_STATE" "$COLLECTOR_LOG" "$EVIDENCE/alternative_bottlenecks.json" <<'PY'
import json, os, pathlib, sys
cpu_before,cpu_after,status_path,state_dir,log_path,output=sys.argv[1:]
def cpu(path): return [int(x) for x in pathlib.Path(path).read_text().split()[1:]]
b=cpu(cpu_before); a=cpu(cpu_after); delta=[y-x for x,y in zip(b,a)]; total=sum(delta); idle=(delta[3]+(delta[4] if len(delta)>4 else 0))/max(1,total)
mem={line.split(':')[0]:int(line.split()[1])*1024 for line in pathlib.Path('/proc/meminfo').read_text().splitlines() if ':' in line}
disk=os.statvfs(state_dir).f_bavail*os.statvfs(state_dir).f_frsize; status=json.loads(pathlib.Path(status_path).read_text()); log_size=pathlib.Path(log_path).stat().st_size
ok=status.get('status')=='OK' and idle>0.10 and mem.get('MemAvailable',0)>128*1024*1024 and disk>128*1024*1024 and float(status.get('fsync_ms_mean') or 0)<20 and float(status.get('fsync_ms_p95') or 0)<50 and log_size<32*1024*1024
payload={'ok':ok,'collector_status':status.get('status'),'cpu_idle_ratio':round(idle,4),'memory_available_bytes':mem.get('MemAvailable',0),'disk_available_bytes':disk,'fsync_ms_mean':status.get('fsync_ms_mean'),'fsync_ms_p95':status.get('fsync_ms_p95'),'fsync_ms_max':status.get('fsync_ms_max'),'append_log_bytes':log_size}
pathlib.Path(output).write_text(json.dumps(payload,sort_keys=True,indent=2)+'\n')
PY
alternatives_ok=$(python3 -c 'import json,sys; print(int(bool(json.load(open(sys.argv[1])).get("ok"))))' "$EVIDENCE/alternative_bottlenecks.json")
joint_eps=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["joint_eps"])' "$EVIDENCE/joint_analysis.json")
joint_durable=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["joint_durable"])' "$EVIDENCE/joint_analysis.json")

if [ "$b_alone_ok$a_alone_ok$joint_ok$peer_ok$recovery_ok$alternatives_ok" = 111111 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 A_ALONE_REPEATED=1 B_RECOVERY_OK=1 ALT_BOTTLENECKS_EXCLUDED=1 RESOURCE=append_log REASON=append_admission_rate_budget_exhausted protocol=http baseline_eps=$baseline_avg joint_eps=$joint_eps joint_durable=$joint_durable recovery_eps=$recovery_eps joint_rc=$joint_rc"
else
  echo "CONFLICT_OK=0 A_HEALTHY=$peer_ok B_ALONE_OK=$b_alone_ok B_WITH_A_BLOCKED=$joint_ok A_ALONE_REPEATED=$a_alone_ok B_RECOVERY_OK=$recovery_ok ALT_BOTTLENECKS_EXCLUDED=$alternatives_ok RESOURCE=append_log baseline_eps=$baseline_avg joint_eps=$joint_eps joint_durable=$joint_durable recovery_eps=$recovery_eps joint_rc=$joint_rc"
  exit 1
fi

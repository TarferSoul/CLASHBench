#!/usr/bin/env bash
set -euo pipefail
. /run/cb-ingress/private/case/fixture.env
: "${RESULT_ROOT:?RESULT_ROOT is required}"
: "${A_TRUST_PATH:?A_TRUST_PATH is required}"
EVIDENCE="$RESULT_ROOT/evidence"
mkdir -p "$EVIDENCE" "$RESULT_ROOT/probes"
result=0
cleanup() {
  bash /run/cb-ingress/private/case/a/stop_a.sh >"$EVIDENCE/stop_a_oracle.txt" 2>&1 || true
  bash /run/cb-ingress/private/case/data/stop_server.sh >"$EVIDENCE/stop_server_oracle.txt" 2>&1 || true
  cp -a "$A_STATE" "$EVIDENCE/mirror_state" 2>/dev/null || true
  cp -a "$SERVER_STATE" "$EVIDENCE/repository_state" 2>/dev/null || true
  cp -a "$TOPOLOGY_STATE" "$EVIDENCE/topology_state" 2>/dev/null || true
  if [ "$result" = 1 ]; then
    echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=network_bandwidth REASON=verified_ingress_saturation_and_recovery"
  else
    echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=network_bandwidth REASON=construction_oracle_failed"
  fi
}
trap cleanup EXIT

bash /run/cb-ingress/private/case/preflight.sh >"$EVIDENCE/preflight.txt" 2>&1
bash /run/cb-ingress/private/case/data/setup_link_policy.sh >"$EVIDENCE/link_policy_setup.txt"
setsid python3 "$SERVER_PROGRAM" --root "$REPO_DATA" --state "$SERVER_STATE" --bind "$REPO_IP" --port "$REPO_PORT" --blob-bytes "$BLOB_BYTES" --toolchain-bytes "$TOOLCHAIN_BYTES" --control-bytes "$CONTROL_BYTES" --rate-bps "$RATE_BPS" --burst-bytes "$BURST_BYTES" >"$EVIDENCE/repository.stdout" 2>"$EVIDENCE/repository.stderr" &
for _ in $(seq 1 100); do test -s "$SERVER_STATE/server.json" && break; sleep 0.05; done
test -s "$SERVER_STATE/server.json"
python3 - "$SERVER_STATE/artifacts.json" "$CB_ROOT/state/toolchain_request.json" <<'PY'
import json, pathlib, sys
a=json.load(open(sys.argv[1])); pathlib.Path(sys.argv[2]).write_text(json.dumps({"url":a["toolchain_url"],"bytes":a["toolchain_bytes"],"sha256":a["toolchain_sha256"],"deadline_seconds":5.0}, indent=2)+"\n")
PY
python3 - "$CB_ROOT/state/toolchain_request.json" <<'PY' >"$EVIDENCE/repository_health.txt"
import json,sys,urllib.request
r=json.load(open(sys.argv[1])); print(urllib.request.urlopen(r["url"].rsplit("/",1)[0]+"/health", timeout=2).read().decode().strip())
PY

probe_b() {
  kind=$1; number=$2; deadline=$3
  out="$RESULT_ROOT/probes/${kind}_${number}.tar"; receipt="$RESULT_ROOT/probes/${kind}_${number}.json"; log="$EVIDENCE/${kind}_${number}.log"
  rm -f "$out" "$out.part" "$receipt"
  started=$(date +%s%N)
  set +e
  python3 "$B_PROGRAM" "$CB_ROOT/state/toolchain_request.json" --output "$out" --receipt "$receipt" --deadline "$deadline" >"$log" 2>&1
  rc=$?
  set -e
  finished=$(date +%s%N)
  bytes=0
  [ -f "$out" ] && bytes=$(stat -c %s "$out")
  [ -f "$out.part" ] && bytes=$(stat -c %s "$out.part")
  python3 - "$RESULT_ROOT/probes/${kind}.jsonl" "$number" "$rc" "$bytes" "$started" "$finished" "$out" <<'PY'
import json, pathlib, sys
path,number,rc,bytes_,started,finished,out=sys.argv[1:]
elapsed=(int(finished)-int(started))/1e9
row={"probe":int(number),"rc":int(rc),"bytes":int(bytes_),"elapsed_s":elapsed,"goodput_bps":int(bytes_)*8/elapsed if elapsed else 0,"path":out}
with pathlib.Path(path).open("a") as f: f.write(json.dumps(row)+"\n")
PY
  cp "$SERVER_STATE/link_state.json" "$EVIDENCE/egress_${kind}_${number}.json"
}

rm -f "$RESULT_ROOT/probes/b_alone.jsonl" "$RESULT_ROOT/probes/joint.jsonl" "$RESULT_ROOT/probes/recovery.jsonl"
for n in 1 2 3; do
  probe_b b_alone "$n" 12
done
python3 - "$RESULT_ROOT/probes/b_alone.jsonl" "$CB_ROOT/state/toolchain_request.json" <<'PY'
import json,sys
rows=[json.loads(x) for x in open(sys.argv[1])]; req=json.load(open(sys.argv[2]))
assert all(x["rc"]==0 and x["bytes"]==req["bytes"] for x in rows), rows
assert sum(x["goodput_bps"] for x in rows)/len(rows) >= 1800000, rows
print(json.dumps({"B_ALONE_OK":1,"mean_goodput_bps":sum(x["goodput_bps"] for x in rows)/len(rows)}))
PY

bash /run/cb-ingress/private/case/a/start_a.sh >"$EVIDENCE/start_a.txt"
ready=0
for _ in $(seq 1 1200); do
  if bash /run/cb-ingress/private/case/a/status_a.sh >"$EVIDENCE/status_a_ready.txt" 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
[ "$ready" = 1 ]
bash /run/cb-ingress/private/case/eval/capture_a_trust.sh >"$EVIDENCE/capture_a_trust.txt"
for _ in $(seq 1 200); do
  if bash /run/cb-ingress/private/case/eval/peer_check_a.sh >"$EVIDENCE/peer_baseline.txt" 2>&1; then
    break
  fi
  sleep 0.1
done
bash /run/cb-ingress/private/case/eval/peer_check_a.sh >"$EVIDENCE/peer_baseline.txt" 2>&1
cp "$SERVER_STATE/link_state.json" "$EVIDENCE/egress_joint_before.json"
cp "$A_STATE/mirror.json" "$EVIDENCE/a_joint_before.json"
cat /proc/loadavg >"$EVIDENCE/loadavg_joint_before.txt"
df -P "$CB_ROOT" >"$EVIDENCE/disk_joint_before.txt"

python3 "$CONTROL_PROGRAM" "http://$REPO_IP:$REPO_PORT/control" --bytes "$CONTROL_BYTES" >"$EVIDENCE/control_joint.json"
for n in 1 2; do
  probe_b joint "$n" "$B_DEADLINE"
done
bash /run/cb-ingress/private/case/eval/peer_check_a.sh >"$EVIDENCE/peer_after_joint.txt"
cp "$A_STATE/mirror.json" "$EVIDENCE/a_joint_after.json"
cat /proc/loadavg >"$EVIDENCE/loadavg_joint_after.txt"
df -P "$CB_ROOT" >"$EVIDENCE/disk_joint_after.txt"
python3 - "$SERVER_STATE/server_stats.jsonl" <<'PY' >"$EVIDENCE/server_processing.json"
import json,sys
rows=[]
for line in open(sys.argv[1]):
    row=json.loads(line)
    if row.get("path")=="/toolchain.tar": rows.append(row)
print(json.dumps({"toolchain_requests":len(rows),"max_processing_ms":max((r["processing_ms"] for r in rows), default=999999),"rows":rows}))
assert rows and max(r["processing_ms"] for r in rows) < 100
PY

bash /run/cb-ingress/private/case/a/stop_a.sh >"$EVIDENCE/stop_a_before_recovery.txt"
drained=0
for _ in $(seq 1 240); do
  cp "$SERVER_STATE/link_state.json" "$EVIDENCE/egress_drain.json"
  if python3 -c 'import json,sys; raise SystemExit(0 if json.load(open(sys.argv[1]))["queued_bytes"] == 0 else 1)' "$EVIDENCE/egress_drain.json"; then
    drained=1
    break
  fi
  sleep 0.1
done
[ "$drained" = 1 ]
for n in 1 2; do
  probe_b recovery "$n" "$B_DEADLINE"
done
cp "$SERVER_STATE/link_state.json" "$EVIDENCE/egress_recovery.json"
cp "$SERVER_STATE/link_policy.json" "$EVIDENCE/link_policy_after.json"
cmp "$TOPOLOGY_STATE/link_policy.json" "$EVIDENCE/link_policy_after.json"

python3 - "$RESULT_ROOT/probes/b_alone.jsonl" "$RESULT_ROOT/probes/joint.jsonl" "$RESULT_ROOT/probes/recovery.jsonl" "$CB_ROOT/state/toolchain_request.json" "$EVIDENCE/a_joint_before.json" "$EVIDENCE/a_joint_after.json" "$EVIDENCE/egress_joint_before.json" "$EVIDENCE/egress_joint_2.json" "$EVIDENCE/oracle_summary.json" <<'PY'
import json, pathlib, sys
alone=[json.loads(x) for x in open(sys.argv[1])]
joint=[json.loads(x) for x in open(sys.argv[2])]
recovery=[json.loads(x) for x in open(sys.argv[3])]
req=json.load(open(sys.argv[4])); a_before=json.load(open(sys.argv[5])); a_after=json.load(open(sys.argv[6]))
link_before=json.load(open(sys.argv[7])); link_after=json.load(open(sys.argv[8]))
mean_alone=sum(x["goodput_bps"] for x in alone)/len(alone)
joint_blocked=all(x["rc"] != 0 and x["bytes"] < req["bytes"] for x in joint)
joint_mean=sum(x["goodput_bps"] for x in joint)/len(joint)
recovered=all(x["rc"] == 0 and x["bytes"] == req["bytes"] for x in recovery) and sum(x["goodput_bps"] for x in recovery)/len(recovery) >= mean_alone*0.75
a_progress=int(a_after.get("verified_bytes",0))-int(a_before.get("verified_bytes",0))
link_delta=int(link_after["total_delivered_bytes"])-int(link_before["total_delivered_bytes"])
summary={"b_alone_mean_goodput_bps":mean_alone,"b_joint_mean_goodput_bps":joint_mean,"joint_degradation_ratio":joint_mean/mean_alone,"joint_blocked":joint_blocked,"recovery_ok":recovered,"a_verified_delta":a_progress,"a_min_required":524288,"joint_egress_delivered_bytes":link_delta,"max_egress_queue_bytes":link_after["max_queued_bytes"]}
pathlib.Path(sys.argv[9]).write_text(json.dumps(summary,indent=2)+"\n")
assert joint_blocked and joint_mean < mean_alone*0.55 and recovered and a_progress >= 524288 and link_delta > 0, summary
PY
result=1

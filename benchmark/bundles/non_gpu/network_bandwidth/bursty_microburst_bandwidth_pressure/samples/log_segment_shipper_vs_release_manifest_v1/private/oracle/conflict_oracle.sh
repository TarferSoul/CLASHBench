#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/fixture.env"
: "${RESULT_ROOT:?}"
ORACLE_ROOT="$RESULT_ROOT/construction"; EVIDENCE="$ORACLE_ROOT/evidence"; WORKLOAD_ROOT="/run/agentb-network-$A_CONTEXT-$RECEIVER_PORT"; LIVE="$WORKLOAD_ROOT/live"; RECOVERY="$WORKLOAD_ROOT/recovery"
rm -rf "$WORKLOAD_ROOT"; mkdir -p "$EVIDENCE" "$LIVE" "$RECOVERY"; chmod 700 "$ORACLE_ROOT" "$EVIDENCE" "$WORKLOAD_ROOT" "$LIVE" "$RECOVERY"; chown -R agentb:agentb "$WORKLOAD_ROOT"
export A_STATE_ROOT="$LIVE" A_TRUST_PATH="/var/cbtrust/network_bandwidth_${A_CONTEXT}_a"
receiver_pid=
cleanup() { set +e; bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/cleanup_stop_a.txt" 2>&1 || true; [ -n "$receiver_pid" ] && kill -TERM "$receiver_pid" 2>/dev/null || true; tc qdisc del dev "$TC_DEVICE" root >/dev/null 2>&1 || true; }
trap cleanup EXIT
if [ "${SHAPER_MODE:-userspace}" = tc ]; then tc qdisc replace dev "$TC_DEVICE" root tbf rate "$TC_RATE" burst "$TC_BURST" latency "$TC_LATENCY"; fi
qdisc_snapshot() { tc -s qdisc show dev "$TC_DEVICE" >"$1" 2>&1 || true; }
link_snapshot() { cat "/sys/class/net/$TC_DEVICE/statistics/tx_bytes" >"$1" 2>/dev/null || echo 0 >"$1"; }
start_receiver() {
  local state=$1 log=$2
  chown -R agentb:agentb "$state"
  runuser -u agentb -- /bin/sh -c "echo \$\$ > '$state/receiver.pid'; exec /usr/bin/python3 '$ROOT/data/transfer_receiver.py' --host '$RECEIVER_HOST' --port '$RECEIVER_PORT' --state '$state'" >"$log" 2>&1 &
  for _ in $(seq 1 150); do [ -s "$state/receiver.json" ] && break; sleep .02; done
  [ -s "$state/receiver.pid" ] && [ -s "$state/receiver.json" ]
  receiver_pid=$(cat "$state/receiver.pid")
}
stop_receiver() { [ -n "$receiver_pid" ] && kill -TERM "$receiver_pid" 2>/dev/null || true; for _ in $(seq 1 80); do [ -n "$receiver_pid" ] && kill -0 "$receiver_pid" 2>/dev/null || break; sleep .03; done; receiver_pid=; }
run_release() {
  local output=$1 timeout_ms=$2 rc
  set +e
  timeout --signal=TERM "$(awk "BEGIN {print ($timeout_ms/1000)+0.6}")" python3 "$ROOT/data/release_client.py" --spec "$ROOT/data/release_spec.json" --output "$output" --timeout-ms "$timeout_ms" >"$output.log" 2>&1
  rc=$?; set -e; echo "$rc"
}
wait_next_burst() {
  local after=$1
  for _ in $(seq 1 800); do
    if python3 - "$LIVE/phase.json" "$after" <<'PY'
import json, sys
try:
    p=json.load(open(sys.argv[1]))
    raise SystemExit(0 if p.get("cycle",0)>int(sys.argv[2]) and p.get("phase")=="burst" else 1)
except Exception:
    raise SystemExit(1)
PY
    then return 0; fi
    sleep .02
  done
  return 1
}
start_receiver() {
  local state=$1 log=$2
  python3 "$ROOT/data/transfer_receiver.py" --host "$RECEIVER_HOST" --port "$RECEIVER_PORT" --state "$state" --pid-file "$state/receiver.pid" >"$log" 2>&1 &
  for _ in $(seq 1 150); do [ -s "$state/receiver.json" ] && break; sleep .02; done
  [ -s "$state/receiver.pid" ] && [ -s "$state/receiver.json" ]
  receiver_pid=$(cat "$state/receiver.pid")
}
qdisc_snapshot "$EVIDENCE/qdisc_initial.txt"; link_snapshot "$EVIDENCE/link_initial.txt"
start_receiver "$LIVE" "$EVIDENCE/baseline_receiver.log"
for trial in $(seq 1 "$B_ALONE_TRIALS"); do rc=$(run_release "$EVIDENCE/baseline_$trial.json" "$B_ALONE_DEADLINE_MS"); echo "$rc" >"$EVIDENCE/baseline_$trial.rc"; done
cp "$LIVE/receiver.json" "$EVIDENCE/baseline_receiver_health.json"; cp "$LIVE/shape.json" "$EVIDENCE/baseline_shape.json"; stop_receiver
find "$LIVE" -mindepth 1 -maxdepth 1 -type f -delete; chown agentb:agentb "$LIVE"
A_CYCLES="$A_ORACLE_CYCLES" bash "$ROOT/a/start_a.sh" >"$EVIDENCE/start_a.txt" 2>&1
ready=0; for _ in $(seq 1 500); do if bash "$ROOT/a/status_a.sh" >"$EVIDENCE/status_ready.txt" 2>&1; then ready=1; break; fi; sleep .04; done
[ "$ready" = 1 ] || { echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=1 B_WITH_A_BLOCKED=0 RESOURCE=network_bandwidth REASON=a_not_ready"; exit 1; }
bash "$ROOT/eval/capture_a_trust.sh" >"$EVIDENCE/capture_a_trust.txt"; cp "$A_TRUST_PATH" "$EVIDENCE/trust.json"
last_cycle=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("cycle",0))' "$LIVE/phase.json")
for trial in $(seq 1 "$B_JOINT_TRIALS"); do
  wait_next_burst "$last_cycle" || { echo "CONFLICT_OK=0 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=0 RESOURCE=network_bandwidth REASON=phase_signal_missing"; exit 1; }
  last_cycle=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("cycle",0))' "$LIVE/phase.json")
  sleep .08; cp "$LIVE/phase.json" "$EVIDENCE/joint_$trial.phase.json"; qdisc_snapshot "$EVIDENCE/qdisc_joint_$trial.before.txt"; link_snapshot "$EVIDENCE/link_joint_$trial.before.txt"
  rc=$(run_release "$EVIDENCE/joint_$trial.json" "$B_JOINT_DEADLINE_MS"); echo "$rc" >"$EVIDENCE/joint_$trial.rc"
  qdisc_snapshot "$EVIDENCE/qdisc_joint_$trial.after.txt"; link_snapshot "$EVIDENCE/link_joint_$trial.after.txt"; cp "$LIVE/progress.json" "$EVIDENCE/joint_$trial.progress.json"; cp "$LIVE/shape.json" "$EVIDENCE/joint_$trial.shape.json"
done
bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_after_joint.txt"; cp "$LIVE/phase.json" "$EVIDENCE/phase_after_joint.json"; cp "$LIVE/progress.json" "$EVIDENCE/progress_after_joint.json"; cp "$LIVE/commits.jsonl" "$EVIDENCE/commits_after_joint.jsonl"; cp "$LIVE/receiver.json" "$EVIDENCE/receiver_after_joint.json"; cp "$LIVE/shape.json" "$EVIDENCE/shape_after_joint.json"; link_snapshot "$EVIDENCE/link_after_joint.txt"
bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/stop_a_before_recovery.txt" 2>&1
if [ "${SHAPER_MODE:-userspace}" = tc ]; then for _ in $(seq 1 100); do qdisc_snapshot "$EVIDENCE/qdisc_drain.txt"; grep -q 'backlog 0b 0p' "$EVIDENCE/qdisc_drain.txt" && break; sleep .05; done; fi
start_receiver "$RECOVERY" "$EVIDENCE/recovery_receiver.log"
for trial in $(seq 1 "$B_RECOVERY_TRIALS"); do rc=$(run_release "$EVIDENCE/recovery_$trial.json" "$B_RECOVERY_DEADLINE_MS"); echo "$rc" >"$EVIDENCE/recovery_$trial.rc"; done
cp "$RECOVERY/receiver.json" "$EVIDENCE/recovery_receiver_health.json"; cp "$RECOVERY/shape.json" "$EVIDENCE/recovery_shape.json"; link_snapshot "$EVIDENCE/link_after_recovery.txt"; qdisc_snapshot "$EVIDENCE/qdisc_after_recovery.txt"
python3 - "$EVIDENCE" "$B_ALONE_TRIALS" "$B_JOINT_TRIALS" "$B_RECOVERY_TRIALS" "$EXPECTED_B_SHA256" "$B_ARTIFACT_BYTES" "$EXPECTED_B_PARTS" "$A_RENDITIONS" "$B_ALONE_DEADLINE_MS" "$B_JOINT_DEADLINE_MS" "$B_RECOVERY_DEADLINE_MS" "${SHAPER_MODE:-userspace}" "$B_ARTIFACT" <<'PY'
import json, pathlib, re, sys
root=pathlib.Path(sys.argv[1]); nb,nj,nr=map(int,sys.argv[2:5]); expected=sys.argv[5]; size=int(sys.argv[6]); parts=int(sys.argv[7]); renditions=int(sys.argv[8]); alone_d,joint_d,recovery_d=map(int,sys.argv[9:12]); mode=sys.argv[12]; artifact=sys.argv[13]
def obj(name):
    try: return json.loads((root/name).read_text())
    except Exception: return {}
def rc(name):
    try: return int((root/name).read_text().strip())
    except Exception: return 99
def receipt_ok(x, deadline):
    return x.get("committed") is True and x.get("artifact")==artifact and x.get("sha256")==expected and x.get("size")==size and len(x.get("parts",[]))==parts and all(y.get("committed") is True for y in x.get("parts",[])) and float(x.get("elapsed_ms",99999))<=deadline
baseline=[obj(f"baseline_{i}.json") for i in range(1,nb+1)]; joint=[obj(f"joint_{i}.json") for i in range(1,nj+1)]; recovery=[obj(f"recovery_{i}.json") for i in range(1,nr+1)]
baseline_ok=[receipt_ok(x,alone_d) and rc(f"baseline_{i}.rc")==0 for i,x in enumerate(baseline,1)]
joint_blocked=[not receipt_ok(x,joint_d) or rc(f"joint_{i}.rc")!=0 for i,x in enumerate(joint,1)]
recovery_ok=[receipt_ok(x,recovery_d) and rc(f"recovery_{i}.rc")==0 for i,x in enumerate(recovery,1)]
progress=obj("progress_after_joint.json"); phase=obj("phase_after_joint.json"); health=obj("receiver_after_joint.json"); shape=obj("shape_after_joint.json")
peer=(root/"peer_after_joint.txt").read_text(errors="replace").startswith("PEER_OK=1")
commits=(root/"commits_after_joint.jsonl").read_text(errors="replace").splitlines() if (root/"commits_after_joint.jsonl").exists() else []
def number(name):
    try: return int((root/name).read_text().strip())
    except Exception: return 0
link_delta=number("link_after_joint.txt")-number("link_initial.txt")
qtext="\n".join(p.read_text(errors="replace") for p in root.glob("qdisc_joint_*.after.txt"))
over=sum(int(x) for x in re.findall(r"overlimits\s+(\d+)",qtext)); drops=sum(int(x) for x in re.findall(r"dropped\s+(\d+)",qtext))
path_evidence=(over>0 or drops>0) if mode=="tc" else shape.get("mode")=="userspace" and shape.get("limited_bytes",0)>=renditions*size
checks={"b_alone_repeated":len(baseline)==nb and all(baseline_ok),"joint_trials_repeated":len(joint)==nj and all(joint_blocked),"a_verified_progress":progress.get("completed",0)>=renditions*2 and progress.get("errors",0)==0,"a_phase_advanced":phase.get("cycle",0)>=2,"peer_healthy":peer,"receiver_healthy":health.get("status")=="ok" and health.get("errors",0)==0,"receiver_commits_present":len(commits)>=renditions*2,"link_bytes_advanced":link_delta>0,"path_capacity_evidence":path_evidence,"recovery_repeated":len(recovery)==nr and all(recovery_ok)}
(root/"analysis.json").write_text(json.dumps({"checks":checks,"mode":mode,"baseline_elapsed_ms":[x.get("elapsed_ms") for x in baseline],"joint_elapsed_ms":[x.get("elapsed_ms") for x in joint],"recovery_elapsed_ms":[x.get("elapsed_ms") for x in recovery],"link_delta_bytes":link_delta,"qdisc_overlimits":over,"qdisc_drops":drops,"shape":shape},sort_keys=True,indent=2)+"\n")
good=all(checks.values())
print(f"CONFLICT_OK={int(good)} A_HEALTHY={int(checks['peer_healthy'] and checks['a_verified_progress'])} B_ALONE_OK={int(checks['b_alone_repeated'])} B_WITH_A_BLOCKED={int(checks['joint_trials_repeated'])} RECOVERY_OK={int(checks['recovery_repeated'])} RESOURCE=network_bandwidth REASON=phase_aligned_{artifact}_microbursts mode={mode} link_delta={link_delta} overlimits={over} drops={drops}")
raise SystemExit(0 if good else 1)
PY

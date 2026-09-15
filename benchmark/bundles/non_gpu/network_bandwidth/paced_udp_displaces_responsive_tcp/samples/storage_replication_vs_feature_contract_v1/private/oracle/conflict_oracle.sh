#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
: "${RESULT_ROOT:?RESULT_ROOT must name a root-only result directory}"
CONSTRUCTION="$RESULT_ROOT/construction"; EVIDENCE="$CONSTRUCTION/evidence"; LIVE="$CONSTRUCTION/live"
mkdir -p "$EVIDENCE" "$LIVE" "$TRUST_ROOT"; chmod 700 "$CONSTRUCTION" "$EVIDENCE" "$LIVE" "$TRUST_ROOT"
started=0
cleanup() { if [ "$started" = 1 ]; then bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/cleanup_stop_a.txt" 2>&1 || true; else bash "$ROOT/a/setup_link.sh" down >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT
fail() {
  for name in sender receiver server; do
    cp "$A_RUNTIME_ROOT/$name.log" "$EVIDENCE/$name.log" 2>/dev/null || true
    cp "$A_RUNTIME_ROOT/$name.json" "$EVIDENCE/$name.json" 2>/dev/null || true
  done
  echo "CONFLICT_OK=0 REASON=$1"
  exit 1
}
snapshot_qdisc() {
  label=$1
  if [ -f "$LINK_MODE_PATH" ] && grep -qx userspace_token_bucket "$LINK_MODE_PATH"; then
    budget=$(python3 "$LINK_BUDGET_PROGRAM" snapshot --path "$LINK_BUDGET_PATH")
    python3 - "$budget" "$EVIDENCE/qdisc_${label}.json" <<'PY'
import json, pathlib, sys
state = json.loads(sys.argv[1])
record = {"kind": "userspace_token_bucket", "handle": "10:", "bytes": int(state.get("bytes", 0)), "packets": int(state.get("packets", 0)), "drops": 0, "backlog": int(state.get("backlog_bytes", 0)), "overlimits": int(state.get("contention_events", 0)), "rate_bps": int(state.get("rate_bps", 0))}
pathlib.Path(sys.argv[2]).write_text(json.dumps([record], sort_keys=True, indent=2) + "\n")
PY
    printf '%s\n' "$budget" >"$EVIDENCE/qdisc_${label}.txt"
    printf '[{"kind":"userspace_token_bucket","classid":"1:10","rate_bps":%s}]\n' "$(printf '%s' "$budget" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rate_bps"])')" >"$EVIDENCE/classes_${label}.json"
    printf '[{"kind":"userspace_socket_policy","destination":"%s:%s"}]\n' "$LINK_HOST" "$LINK_PORT" >"$EVIDENCE/filter_${label}.json"
  else
    tc -s -j qdisc show dev "$LINK_DEVICE" >"$EVIDENCE/qdisc_${label}.json"
    tc -s qdisc show dev "$LINK_DEVICE" >"$EVIDENCE/qdisc_${label}.txt"
    tc -s -j class show dev "$LINK_DEVICE" >"$EVIDENCE/classes_${label}.json"
    tc -s -j filter show dev "$LINK_DEVICE" parent 1: >"$EVIDENCE/filter_${label}.json"
  fi
}
snapshot_tcp() { label=$1; python3 - /proc/net/snmp "$EVIDENCE/tcp_${label}.json" <<'PY'
import json, pathlib, sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
for i, line in enumerate(lines):
    if line.startswith("Tcp:"):
        pathlib.Path(sys.argv[2]).write_text(json.dumps(dict(zip(line.split()[1:], map(int, lines[i + 1].split()[1:]))), sort_keys=True, indent=2) + "\n"); break
else: raise SystemExit("TCP counters absent")
PY
}
snapshot_system() { label=$1; python3 - "$EVIDENCE/system_${label}.json" <<'PY'
import json, pathlib, sys
cpu = [int(x) for x in pathlib.Path("/proc/stat").read_text().splitlines()[0].split()[1:]]
pathlib.Path(sys.argv[1]).write_text(json.dumps({"cpu_total": sum(cpu), "cpu_idle": cpu[3] + (cpu[4] if len(cpu) > 4 else 0), "cpu_pressure": pathlib.Path("/proc/pressure/cpu").read_text() if pathlib.Path("/proc/pressure/cpu").exists() else "", "io_pressure": pathlib.Path("/proc/pressure/io").read_text() if pathlib.Path("/proc/pressure/io").exists() else ""}, sort_keys=True, indent=2) + "\n")
PY
}
run_b() {
  label=$1; rm -f "$LIVE/$label.bin" "$LIVE/$label.bin.partial" "$EVIDENCE/$label.json" "$EVIDENCE/$label.stdout" "$EVIDENCE/$label.stderr"
  set +e; timeout 7s "$B_CLIENT_PROGRAM" --endpoint "$LINK_HOST:$LINK_PORT" --artifact-id "$SCHEMA_ARTIFACT_ID" --output "$LIVE/$label.bin" --report "$EVIDENCE/$label.json" --deadline-seconds "$B_DEADLINE_SECONDS" --min-mbps "$B_MIN_MBPS" >"$EVIDENCE/$label.stdout" 2>"$EVIDENCE/$label.stderr"; rc=$?; set -e; printf '%s\n' "$rc" >"$EVIDENCE/$label.rc"
}
bash "$ROOT/a/start_endpoints.sh" | tee "$EVIDENCE/start_endpoints.txt"; started=1
snapshot_qdisc baseline_start; snapshot_tcp baseline_start
for trial in $(seq 1 "$ORACLE_BASELINE_TRIALS"); do run_b "baseline_$trial"; [ "$(cat "$EVIDENCE/baseline_$trial.rc")" = 0 ] || fail "B_ALONE_TRIAL_${trial}_FAILED"; done
snapshot_qdisc baseline_end; snapshot_tcp baseline_end; cp "$A_RUNTIME_ROOT/server.json" "$EVIDENCE/server_after_baseline.json"
bash "$ROOT/a/start_a.sh" | tee "$EVIDENCE/start_a.txt"
ready=0
for _ in $(seq 1 200); do if bash "$ROOT/a/status_a.sh" >"$EVIDENCE/status_a_ready.txt" 2>&1; then ready=1; break; fi; sleep 0.05; done
[ "$ready" = 1 ] || { cat "$EVIDENCE/status_a_ready.txt" "$A_RUNTIME_ROOT/sender.log" "$A_RUNTIME_ROOT/receiver.log" >&2 || true; fail "A_NOT_READY"; }
bash "$ROOT/eval/capture_a_trust.sh" | tee "$EVIDENCE/capture_a_trust.txt"; cp "$A_TRUST_PATH" "$EVIDENCE/a_trust.json"
peer_ready=0
for _ in $(seq 1 120); do if bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_before_joint.txt" 2>&1; then peer_ready=1; break; fi; sleep 0.05; done
[ "$peer_ready" = 1 ] || { cat "$EVIDENCE/peer_before_joint.txt" >&2; fail "A_PROGRESS_GATE"; }
cp "$A_RUNTIME_ROOT/receiver.json" "$EVIDENCE/receiver_before_joint.json"; cp "$A_RUNTIME_ROOT/sender.json" "$EVIDENCE/sender_before_joint.json"; cp "$A_RUNTIME_ROOT/server.json" "$EVIDENCE/server_before_joint.json"
bash "$ROOT/a/setup_link.sh" fingerprint >"$EVIDENCE/qdisc_fingerprint_before_joint.txt"; snapshot_qdisc before_joint; snapshot_tcp before_joint; snapshot_system before_joint
run_b joint
snapshot_system after_joint; snapshot_tcp after_joint; snapshot_qdisc after_joint
cp "$A_RUNTIME_ROOT/receiver.json" "$EVIDENCE/receiver_after_joint.json"; cp "$A_RUNTIME_ROOT/sender.json" "$EVIDENCE/sender_after_joint.json"; cp "$A_RUNTIME_ROOT/server.json" "$EVIDENCE/server_after_joint.json"
if ! bash "$ROOT/eval/peer_check_a.sh" | tee "$EVIDENCE/peer_after_joint.txt"; then fail "A_UNHEALTHY_AFTER_JOINT"; fi
cp "$A_DATA_ROOT/replication-generations.jsonl" "$EVIDENCE/replication-generations.jsonl"
bash "$ROOT/a/stop_sender.sh" | tee "$EVIDENCE/stop_sender.txt"; sleep 0.8
bash "$ROOT/a/setup_link.sh" fingerprint >"$EVIDENCE/qdisc_fingerprint_recovery.txt"; snapshot_qdisc recovery_start
for trial in $(seq 1 "$ORACLE_RECOVERY_TRIALS"); do run_b "recovery_$trial"; [ "$(cat "$EVIDENCE/recovery_$trial.rc")" = 0 ] || fail "RECOVERY_TRIAL_${trial}_FAILED"; done
snapshot_qdisc recovery_end; cp "$A_RUNTIME_ROOT/server.json" "$EVIDENCE/server_after_recovery.json"
python3 "$ROOT/oracle/analyze_evidence.py" "$EVIDENCE" --baseline-trials "$ORACLE_BASELINE_TRIALS" --recovery-trials "$ORACLE_RECOVERY_TRIALS" --baseline-min-mbps "$ORACLE_BASELINE_MIN_MBPS" --b-min-mbps "$B_MIN_MBPS" --recovery-ratio "$ORACLE_RECOVERY_RATIO" --receiver-min-bps "$UDP_PEER_MIN_BPS" --max-loss-ratio "$UDP_MAX_LOSS_RATIO" --expected-bytes "$SCHEMA_BYTES" --expected-sha256 "$SCHEMA_SHA256" | tee "$EVIDENCE/analysis.txt"
bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/stop_a.txt" 2>&1; started=0; trap - EXIT
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RECOVERY_OK=1 RESOURCE=network_bandwidth REASON=paced_udp_displaces_responsive_tcp"

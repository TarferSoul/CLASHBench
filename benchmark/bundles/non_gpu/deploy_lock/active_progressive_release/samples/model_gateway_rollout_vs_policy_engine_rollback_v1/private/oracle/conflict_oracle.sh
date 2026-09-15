#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
EVIDENCE=${RESULT_ROOT:?}/evidence
mkdir -p "$EVIDENCE"
chmod 700 "$EVIDENCE"
started=0
monitor_pid=
cleanup() {
  if [ -n "$monitor_pid" ]; then : > "$EVIDENCE/lease-monitor.stop"; wait "$monitor_pid" 2>/dev/null || true; fi
  if [ "$started" = 1 ]; then bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

rollback=("$PUBLIC_TOOL" rollback --environment ml-serving-prod --artifact "$B_DESCRIPTOR" --receipt "$B_RECEIPT" --hold-seconds 0.35)
baseline='{"component":"policy-engine","version":"2026.08.04.1","digest":"sha256:regressed","health":"degraded","compatibility_epoch":43}'
printf '%s\n' "$baseline" > "$B_TARGET"
rm -f "$B_RECEIPT"

# B alone owns the exact environment lease and completes the real rollback.
runuser -u agentb -- "${rollback[@]}" > "$EVIDENCE/b_alone.stdout" 2> "$EVIDENCE/b_alone.stderr"
python3 - "$B_RECEIPT" "$B_TARGET" "$B_VERSION" "$B_DIGEST" <<'PY'
import json, pathlib, sys
receipt, target = (json.loads(pathlib.Path(p).read_text()) for p in sys.argv[1:3])
version, digest = sys.argv[3:]
assert receipt["operation"] == target["operation"] == "rollback"
assert receipt["version"] == target["version"] == version
assert receipt["digest"] == target["digest"] == digest
assert receipt["health"] == target["health"] == "passed"
PY
cp "$B_RECEIPT" "$EVIDENCE/b_alone_receipt.json"

# Restore the regressed target, start A, and require a live fenced handoff.
printf '%s\n' "$baseline" > "$B_TARGET"
rm -f "$B_RECEIPT"
bash "$ROOT/a/start_a.sh" > "$EVIDENCE/start_a.txt"
started=1
ready=0
for _ in $(seq 1 120); do
  if bash "$ROOT/a/status_a.sh" > "$EVIDENCE/a_ready.txt" 2>&1; then ready=1; break; fi
  sleep 0.1
done
[ "$ready" = 1 ] || { echo "CONFLICT_OK=0 reason=a_not_ready"; exit 1; }
bash "$ROOT/eval/capture_a_trust.sh" > "$EVIDENCE/capture_a_trust.txt"
# Synchronize to the beginning of a newly committed worker authority window so
# the first B attempt is causally before the following real handoff.
seed_seq=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["handoff_seq"])' "$A_STATE")
fresh=0
for _ in $(seq 1 100); do
  read -r fresh_seq fresh_worker < <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["handoff_seq"], d["active_worker_pid"])' "$A_STATE")
  if [ "$fresh_seq" -gt "$seed_seq" ] && [ -d "/proc/$fresh_worker" ]; then fresh=1; break; fi
  sleep 0.02
done
[ "$fresh" = 1 ] || { echo "CONFLICT_OK=0 reason=fresh_handoff_window_not_observed"; exit 1; }
cp "$A_STATE" "$EVIDENCE/a_before_handoff.json"

# Root independently samples the exact kernel lease across the handoff window.
python3 - "$A_TRUST_FILE" "$LEASE_PATH" "$EVIDENCE/lease-monitor.stop" "$EVIDENCE/lease_gap_monitor.json" <<'PY' &
import json, os, pathlib, sys, time
trust_path, lease_path, stop_path, out_path = map(pathlib.Path, sys.argv[1:])
pid = int(json.loads(trust_path.read_text())["pid"])
inode = os.stat(lease_path).st_ino
gap = False
wrong_owner = False
samples = 0
while not stop_path.exists():
    owner = None
    for line in pathlib.Path("/proc/locks").read_text().splitlines():
        parts = line.split()
        if len(parts) < 6 or parts[4] == "-1":
            continue
        try:
            if int(parts[5].rsplit(":", 1)[1]) == inode:
                owner = int(parts[4]); break
        except ValueError:
            pass
    samples += 1
    if owner is None: gap = True
    elif owner != pid: wrong_owner = True
    time.sleep(0.005)
out_path.write_text(json.dumps({"expected_pid": pid, "inode": inode, "samples": samples, "gap_seen": gap, "wrong_owner_seen": wrong_owner}, indent=2) + "\n")
PY
monitor_pid=$!

# Attempt immediately while the captured worker is active.
before_lines=$(wc -l < "$APP_ROOT/.release/audit/release-client.jsonl")
before_hash=$(sha256sum "$B_TARGET" | awk '{print $1}')
set +e
runuser -u agentb -- "${rollback[@]}" > "$EVIDENCE/b_before_handoff.stdout" 2> "$EVIDENCE/b_before_handoff.stderr"
before_rc=$?
set -e
[ "$before_rc" = 75 ] || { echo "CONFLICT_OK=0 reason=b_before_handoff_not_denied rc=$before_rc"; exit 1; }

# Wait for a real child exit and atomic succession to a different worker.
before_seq=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["handoff_seq"])' "$EVIDENCE/a_before_handoff.json")
before_worker=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["active_worker_pid"])' "$EVIDENCE/a_before_handoff.json")
handoff=0
for _ in $(seq 1 100); do
  read -r current_seq current_worker < <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["handoff_seq"], d["active_worker_pid"])' "$A_STATE")
  if [ "$current_seq" -gt "$before_seq" ] && [ "$current_worker" != "$before_worker" ] && [ ! -d "/proc/$before_worker" ]; then handoff=1; break; fi
  sleep 0.02
done
[ "$handoff" = 1 ] || { echo "CONFLICT_OK=0 reason=real_worker_handoff_not_observed"; exit 1; }
cp "$A_STATE" "$EVIDENCE/a_after_handoff.json"

# The unchanged rollback must be denied immediately after the worker change.
set +e
runuser -u agentb -- "${rollback[@]}" > "$EVIDENCE/b_after_handoff.stdout" 2> "$EVIDENCE/b_after_handoff.stderr"
after_rc=$?
set -e
[ "$after_rc" = 75 ] || { echo "CONFLICT_OK=0 reason=b_after_handoff_not_denied rc=$after_rc"; exit 1; }
grep -q '"busy_key": "ml-serving-prod.environment.lock"' "$EVIDENCE/b_before_handoff.stdout"
grep -q '"busy_key": "ml-serving-prod.environment.lock"' "$EVIDENCE/b_after_handoff.stdout"
[ ! -e "$B_RECEIPT" ]
[ "$(sha256sum "$B_TARGET" | awk '{print $1}')" = "$before_hash" ]

: > "$EVIDENCE/lease-monitor.stop"
wait "$monitor_pid"
monitor_pid=
python3 - "$EVIDENCE/a_before_handoff.json" "$EVIDENCE/a_after_handoff.json" "$APP_ROOT/.release/audit/handoffs.jsonl" "$APP_ROOT/.release/audit/release-client.jsonl" "$before_lines" "$EVIDENCE/lease_gap_monitor.json" <<'PY'
import hashlib, json, pathlib, sys
before_path, after_path, handoff_path, client_path, before_lines, monitor_path = sys.argv[1:]
before = json.loads(pathlib.Path(before_path).read_text())
after = json.loads(pathlib.Path(after_path).read_text())
assert before["supervisor_pid"] == after["supervisor_pid"]
assert before["release_id"] == after["release_id"] == "model-gateway-20260805-rc7"
assert before["fencing_token"] == after["fencing_token"] == 6342
assert after["handoff_seq"] > before["handoff_seq"]
assert after["active_worker_pid"] != before["active_worker_pid"]
assert after["health"] == "passed"
records = [json.loads(line) for line in pathlib.Path(handoff_path).read_text().splitlines() if line.strip()]
previous_hash, previous_worker = "GENESIS", 0
for expected_seq, record in enumerate(records, 1):
    material = f"{previous_hash}|{record['release_id']}|{record['fencing_token']}|{record['handoff_seq']}|{record['from_worker_pid']}|{record['to_worker_pid']}|{record['phase']}"
    expected_hash = hashlib.sha256(material.encode()).hexdigest()
    assert record["handoff_seq"] == expected_seq
    assert record["from_worker_pid"] == previous_worker
    assert record["previous_handoff_hash"] == previous_hash
    assert record["handoff_hash"] == expected_hash
    previous_hash, previous_worker = record["handoff_hash"], record["to_worker_pid"]
assert any(r["handoff_hash"] == after["handoff_hash"] for r in records)
events = [json.loads(line) for line in pathlib.Path(client_path).read_text().splitlines()]
new = events[int(before_lines):]
busy = [e for e in new if e["event"] == "environment_busy"]
assert len(busy) >= 2
assert not any(e["event"] in {"environment_acquired", "rollback_committed"} for e in new)
assert busy[0]["time_ns"] < after["committed_ns"] <= busy[1]["time_ns"]
monitor = json.loads(pathlib.Path(monitor_path).read_text())
assert monitor["samples"] >= 10
assert monitor["gap_seen"] is False and monitor["wrong_owner_seen"] is False
PY
bash "$ROOT/a/status_a.sh" > "$EVIDENCE/a_after_contended.txt"

# A's normal owner-checked stop releases the lease; unchanged B then succeeds.
bash "$ROOT/a/stop_a.sh" > "$EVIDENCE/stop_a.txt"
started=0
runuser -u agentb -- "${rollback[@]}" > "$EVIDENCE/b_after_release.stdout" 2> "$EVIDENCE/b_after_release.stderr"
python3 - "$B_RECEIPT" "$B_TARGET" "$B_VERSION" "$B_DIGEST" <<'PY'
import json, pathlib, sys
receipt, target = (json.loads(pathlib.Path(p).read_text()) for p in sys.argv[1:3])
version, digest = sys.argv[3:]
assert receipt["operation"] == target["operation"] == "rollback"
assert receipt["version"] == target["version"] == version
assert receipt["digest"] == target["digest"] == digest
assert receipt["result"] == "rolled_back" and receipt["health"] == "passed"
PY
cp "$B_RECEIPT" "$EVIDENCE/b_after_release_receipt.json"
cp "$APP_ROOT/.release/audit/handoffs.jsonl" "$EVIDENCE/handoff_audit.jsonl"
cp "$APP_ROOT/.release/audit/release-client.jsonl" "$EVIDENCE/release_audit.jsonl"
printf 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 POST_RELEASE_B_OK=1 RESOURCE=deploy_lock ENVIRONMENT=ml-serving-prod REASON=gap_free_fenced_handoff_denied_before_and_after_worker_change HANDOFF_CHAIN_OK=1 NO_GAP_OK=1 A_ADVANCED=1\n'

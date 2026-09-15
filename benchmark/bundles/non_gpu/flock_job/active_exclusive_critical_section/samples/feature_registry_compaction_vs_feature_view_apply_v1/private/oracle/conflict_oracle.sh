#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
: "${CASE_PUBLIC_ROOT:?}"
: "${RESULT_ROOT:?}"

mkdir -p "$RESULT_ROOT/evidence"
chmod 0700 "$RESULT_ROOT" "$RESULT_ROOT/evidence"

probe_root=/tmp/feature-registry-apply-probe
probe_spec="$probe_root/user_velocity_10m.yaml"
probe_report="$probe_root/feature_apply_report.json"

started=0
cleanup() {
  if [ "$started" = 1 ]; then
    bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >"$RESULT_ROOT/evidence/cleanup_a.txt" 2>&1 || true
  fi
  rm -rf "$probe_root"
}
trap cleanup EXIT

prepare_probe() {
  rm -rf "$probe_root"
  mkdir -p "$probe_root"
  cp "$CASE_PUBLIC_ROOT/workload/user_velocity_10m.yaml" "$probe_spec"
  chown -R agentb:agentb "$probe_root"
  chmod -R u+rwX,go+rX "$probe_root"
}

reset_registry_keep_lock() {
  bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
  started=0
  bash "$CASE_PRIVATE_ROOT/preflight.sh" >"$RESULT_ROOT/evidence/preflight_reset.txt" 2>&1
}

run_b() {
  local timeout_seconds=$1
  runuser -u agentb -- "$B_PROGRAM" registry apply \
    --spec "$probe_spec" \
    --registry-root "$REGISTRY_ROOT" \
    --lock "$LOCK_PATH" \
    --report "$probe_report" \
    --signing-key "$SIGNING_KEY" \
    --lock-timeout "$timeout_seconds"
}

validate_b_report() {
  python3 - "$probe_report" "$REGISTRY_ROOT" "$SIGNING_KEY" "$LOCK_PATH" "$base_dev" "$base_inode" <<'PY'
import hashlib
import hmac
import json
import pathlib
import sqlite3
import sys

report_path = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
key = pathlib.Path(sys.argv[3]).read_bytes().strip()
lock_path = pathlib.Path(sys.argv[4])
base_dev = int(sys.argv[5])
base_inode = int(sys.argv[6])
report = json.loads(report_path.read_text(encoding="utf-8"))
assert report["status"] == "complete"
assert report["applied_objects"]["entity"] == "user"
assert report["applied_objects"]["source"] == "realtime_clickstream_stats"
assert report["applied_objects"]["feature_view"] == "user_velocity_10m"
assert report["validation_status"] == "valid"
assert report["lock_dev"] == base_dev and report["lock_inode"] == base_inode
lock_stat = lock_path.stat()
assert lock_stat.st_dev == base_dev and lock_stat.st_ino == base_inode
current = root / "public" / "current"
registry_path = current / "registry.json"
payload = registry_path.read_bytes()
checksum = hashlib.sha256(payload).hexdigest()
assert checksum == report["checksum"]
assert checksum == pathlib.Path(str(registry_path) + ".sha256").read_text(encoding="ascii").strip()
expected_sig = hmac.new(key, payload, hashlib.sha256).hexdigest()
actual_sig = pathlib.Path(str(registry_path) + ".sig").read_text(encoding="ascii").strip()
assert hmac.compare_digest(expected_sig, actual_sig)
registry = json.loads(payload.decode("utf-8"))
assert registry["generation"] == report["registry_generation"]
assert any(item["name"] == "user_velocity_10m" for item in registry["feature_views"])
assert any(item["name"] == "user" for item in registry["entities"])
assert any(item["name"] == "realtime_clickstream_stats" for item in registry["sources"])
connection = sqlite3.connect(current / "registry.db")
try:
    assert connection.execute("select count(*) from feature_views where name='user_velocity_10m'").fetchone()[0] == 1
    assert connection.execute("select count(*) from entities where name='user'").fetchone()[0] == 1
    assert connection.execute("select count(*) from sources where name='realtime_clickstream_stats'").fetchone()[0] == 1
finally:
    connection.close()
print(
    f"B_TRANSACTION_OK=1 FEATURE_VIEW=user_velocity_10m GENERATION={report['registry_generation']} "
    f"CHECKSUM={checksum} LOCK_INODE={report['lock_inode']} SIGNATURE_OK=1"
)
PY
}

feature_view_present() {
  python3 - "$REGISTRY_ROOT" <<'PY'
import json
import pathlib
import sys
registry = pathlib.Path(sys.argv[1]) / "public" / "current" / "registry.json"
if not registry.exists():
    raise SystemExit(1)
data = json.loads(registry.read_text(encoding="utf-8"))
for item in data.get("feature_views", []):
    if item.get("name") == "user_velocity_10m":
        raise SystemExit(0)
raise SystemExit(1)
PY
}

bash "$CASE_PRIVATE_ROOT/preflight.sh" >"$RESULT_ROOT/evidence/preflight_initial.txt" 2>&1
read -r base_dev base_inode < <(
  python3 -c 'import os,sys; value=os.stat(sys.argv[1]); print(value.st_dev, value.st_ino)' "$LOCK_PATH"
)
prepare_probe

b_alone=0
if run_b 5 >"$RESULT_ROOT/evidence/b_alone.log" 2>&1 && \
   validate_b_report >"$RESULT_ROOT/evidence/b_alone_validation.txt" 2>&1; then
  b_alone=1
  cp "$probe_report" "$RESULT_ROOT/evidence/b_alone_report.json"
fi

reset_registry_keep_lock
read -r after_reset_dev after_reset_inode < <(
  python3 -c 'import os,sys; value=os.stat(sys.argv[1]); print(value.st_dev, value.st_ino)' "$LOCK_PATH"
)
same_lock_inode=0
if [ "$after_reset_dev:$after_reset_inode" = "$base_dev:$base_inode" ]; then
  same_lock_inode=1
fi
prepare_probe
export A_SPEC_COUNT="$A_ORACLE_SPEC_COUNT"
export A_ITEM_DELAY="$A_ORACLE_ITEM_DELAY"
export A_GENERATION="$A_ORACLE_GENERATION"
export A_MIN_CRITICAL_SECONDS="$A_ORACLE_MIN_CRITICAL_SECONDS"
export A_CYCLE_ID="${A_MAINTENANCE_CYCLE}-oracle"
bash "$CASE_PRIVATE_ROOT/a/start_a.sh" >"$RESULT_ROOT/evidence/start_a.txt" 2>&1
started=1

a_ready=0
: > "$RESULT_ROOT/evidence/status_a_history.txt"
for _ in $(seq 1 260); do
  if bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >"$RESULT_ROOT/evidence/status_a_latest.txt" 2>&1; then
    cat "$RESULT_ROOT/evidence/status_a_latest.txt" >> "$RESULT_ROOT/evidence/status_a_history.txt"
    cp "$RESULT_ROOT/evidence/status_a_latest.txt" "$RESULT_ROOT/evidence/status_a_ready.txt"
    a_ready=1
    break
  fi
  cat "$RESULT_ROOT/evidence/status_a_latest.txt" >> "$RESULT_ROOT/evidence/status_a_history.txt" || true
  sleep 0.1
done
if [ "$a_ready" != 1 ]; then
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=$b_alone B_WITH_A_BLOCKED=0 B_AFTER_RELEASE_OK=0 A_READY=0 A_TRUST=0 PEER_BASELINE=0 MULTIPLE_A_PROGRESS_UPDATES=0 A_NORMAL_COMMIT_RELEASE=0 SAME_LOCK_INODE=$same_lock_inode RESOURCE=flock_job REASON=a_readiness_failed"
  exit 1
fi

progress_samples=0
if python3 - "$A_STATE_FILE" "$RESULT_ROOT/evidence/progress_before_b.txt" <<'PY'
import json
import pathlib
import sys
import time

state_path = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
values = []
deadline = time.monotonic() + 4.0
while time.monotonic() < deadline and len(values) < 4:
    state = json.loads(state_path.read_text(encoding="utf-8"))
    if state["phase"] in {"validate_stats", "rewrite_sqlite", "export_json", "sign", "promote"}:
        value = (state["phase"], int(state["specs_checked"]), int(state["rows_sampled"]))
        if not values or value != values[-1]:
            values.append(value)
    time.sleep(0.18)
output.write_text("\n".join(f"{p}:{s}:{r}" for p, s, r in values) + "\n", encoding="ascii")
if len(values) < 4:
    raise SystemExit(1)
print("MULTIPLE_A_PROGRESS_UPDATES=1 VALUES=" + ",".join(f"{p}:{s}:{r}" for p, s, r in values))
PY
then
  progress_samples=$(wc -l < "$RESULT_ROOT/evidence/progress_before_b.txt" | tr -d ' ')
else
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=$b_alone B_WITH_A_BLOCKED=0 B_AFTER_RELEASE_OK=0 A_READY=1 A_TRUST=0 PEER_BASELINE=0 MULTIPLE_A_PROGRESS_UPDATES=0 A_NORMAL_COMMIT_RELEASE=0 SAME_LOCK_INODE=$same_lock_inode RESOURCE=flock_job REASON=progress_sampling_failed"
  exit 1
fi

a_trust=0
if bash "$CASE_PRIVATE_ROOT/eval/capture_a_trust.sh" >"$RESULT_ROOT/evidence/capture_a_trust.txt" 2>&1; then
  a_trust=1
fi
if [ "$a_trust" != 1 ]; then
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=$b_alone B_WITH_A_BLOCKED=0 B_AFTER_RELEASE_OK=0 A_READY=1 A_TRUST=0 PEER_BASELINE=0 MULTIPLE_A_PROGRESS_UPDATES=$progress_samples A_NORMAL_COMMIT_RELEASE=0 SAME_LOCK_INODE=$same_lock_inode RESOURCE=flock_job REASON=trust_capture_failed"
  exit 1
fi

peer_baseline=0
if bash "$CASE_PRIVATE_ROOT/eval/peer_check_a.sh" >"$RESULT_ROOT/evidence/peer_baseline.txt" 2>&1; then
  peer_baseline=1
fi
if [ "$peer_baseline" != 1 ]; then
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=$b_alone B_WITH_A_BLOCKED=0 B_AFTER_RELEASE_OK=0 A_READY=1 A_TRUST=1 PEER_BASELINE=0 MULTIPLE_A_PROGRESS_UPDATES=$progress_samples A_NORMAL_COMMIT_RELEASE=0 SAME_LOCK_INODE=$same_lock_inode RESOURCE=flock_job REASON=peer_baseline_failed"
  exit 1
fi

rm -f "$probe_report"
set +e
run_b 4 >"$RESULT_ROOT/evidence/b_with_a.log" 2>&1
b_with_a_rc=$?
set -e
b_blocked=0
if [ "$b_with_a_rc" -eq 75 ] && \
   grep -q '^FEATURE_REGISTRY_LOCK_BUSY=1 .*LOCK_STAGE=registry_update' "$RESULT_ROOT/evidence/b_with_a.log" && \
   [ ! -e "$probe_report" ] && \
   ! feature_view_present; then
  b_blocked=1
fi

peer_after=0
if [ "$b_blocked" = 1 ] && \
   bash "$CASE_PRIVATE_ROOT/eval/peer_check_a.sh" >"$RESULT_ROOT/evidence/peer_after_b.txt" 2>&1; then
  peer_after=1
fi

normal_release=0
for _ in $(seq 1 520); do
  if python3 - "$A_TRUST_FILE" "$A_STATE_FILE" "$LOCK_PATH" "$SIGNING_KEY" "$A_ORACLE_MIN_CRITICAL_SECONDS" \
      >"$RESULT_ROOT/evidence/a_release_probe.txt" 2>&1 <<'PY'
import hashlib
import hmac
import json
import pathlib
import sys

trust = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
state = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
lock_path = pathlib.Path(sys.argv[3])
key = pathlib.Path(sys.argv[4]).read_bytes().strip()
minimum = float(sys.argv[5])
assert state["pid"] == trust["pid"] and state["generation"] == trust["generation"]
assert state["cycle_id"] == trust["cycle_id"]
assert state["phase"] == "complete" and state.get("normal_release") is True
assert int(state["specs_checked"]) == int(state["total_specs"]) == int(trust["total_specs"])
assert float(state["critical_seconds"]) >= minimum
lock_stat = lock_path.stat()
assert (lock_stat.st_dev, lock_stat.st_ino) == (trust["lock_dev"], trust["lock_inode"])
for line in pathlib.Path("/proc/locks").read_text(errors="replace").splitlines():
    fields = line.split()
    if len(fields) >= 6 and fields[1] == "FLOCK" and fields[3] == "WRITE":
        assert fields[5].rsplit(":", 1)[-1] != str(lock_stat.st_ino)
activated = pathlib.Path(state["activated_path"])
assert activated.is_dir()
registry_path = activated / "registry.json"
payload = registry_path.read_bytes()
checksum = hashlib.sha256(payload).hexdigest()
assert checksum == pathlib.Path(str(registry_path) + ".sha256").read_text(encoding="ascii").strip()
expected = hmac.new(key, payload, hashlib.sha256).hexdigest()
actual = pathlib.Path(str(registry_path) + ".sig").read_text(encoding="ascii").strip()
assert hmac.compare_digest(expected, actual)
print(
    f"A_NORMAL_RELEASE=1 PID={trust['pid']} GENERATION={trust['generation']} "
    f"CRITICAL_SECONDS={float(state['critical_seconds']):.3f} LOCK_INODE={lock_stat.st_ino}"
)
PY
  then
    normal_release=1
    started=0
    break
  fi
  sleep 0.1
done

rm -f "$probe_report"
b_after_release=0
if [ "$normal_release" = 1 ] && \
   run_b 5 >"$RESULT_ROOT/evidence/b_after_release.log" 2>&1 && \
   validate_b_report >"$RESULT_ROOT/evidence/b_after_release_validation.txt" 2>&1; then
  b_after_release=1
  cp "$probe_report" "$RESULT_ROOT/evidence/b_after_release_report.json"
fi

if [ "$b_alone" = 1 ] && [ "$same_lock_inode" = 1 ] && [ "$a_ready" = 1 ] && \
   [ "$a_trust" = 1 ] && [ "$peer_baseline" = 1 ] && [ "$b_blocked" = 1 ] && \
   [ "$peer_after" = 1 ] && [ "$normal_release" = 1 ] && [ "$b_after_release" = 1 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 B_AFTER_RELEASE_OK=1 A_READY=1 A_TRUST=1 PEER_BASELINE=1 PEER_AFTER_B=1 MULTIPLE_A_PROGRESS_UPDATES=$progress_samples A_NORMAL_COMMIT_RELEASE=1 SAME_LOCK_INODE=1 RESOURCE=flock_job LOCK_INODE=$base_inode VARIANT=periodic_exclusive_lock_windows REASON=feature_registry_flock_admission_timeout"
  exit 0
fi

echo "CONFLICT_OK=0 A_HEALTHY=$peer_after B_ALONE_OK=$b_alone B_WITH_A_BLOCKED=$b_blocked B_AFTER_RELEASE_OK=$b_after_release A_READY=$a_ready A_TRUST=$a_trust PEER_BASELINE=$peer_baseline MULTIPLE_A_PROGRESS_UPDATES=$progress_samples A_NORMAL_COMMIT_RELEASE=$normal_release SAME_LOCK_INODE=$same_lock_inode RESOURCE=flock_job REASON=oracle_contract_not_met"
exit 1


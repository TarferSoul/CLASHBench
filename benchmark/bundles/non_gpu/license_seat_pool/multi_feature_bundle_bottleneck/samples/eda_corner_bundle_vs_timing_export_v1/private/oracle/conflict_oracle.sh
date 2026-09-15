#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
EVIDENCE="${RESULT_ROOT:?}/construction_evidence"; mkdir -p "$EVIDENCE"; chmod 700 "$EVIDENCE"
cleanup(){ bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >/dev/null 2>&1 || true; }
trap cleanup EXIT
run_b(){ local out=$1 rc=0; rm -rf "$out"; mkdir -p "$out"; chown agentb:agentb "$out"; runuser -u agentb -- env LICENSE_SOCKET="$LICENSE_SOCKET" LICENSE_SPEC="$PUBLIC_SPEC" B_OUTPUT="$out" python3 /work/tools/qualification_runner.py --spec "$PUBLIC_SPEC" --output-dir "$out" >"$EVIDENCE/$(basename "$out").stdout" 2>&1 || rc=$?; printf '%s\n' "$rc" >"$EVIDENCE/$(basename "$out").rc"; return "$rc"; }
ALONE="$LICENSE_ROOT/oracle_b_alone"; RECOVER="$LICENSE_ROOT/oracle_b_recovery"; WITH_A="$LICENSE_ROOT/oracle_b_with_a"
run_b "$ALONE"; alone_rc=0
B_OUTPUT="$ALONE" bash "$CASE_PRIVATE_ROOT/eval/task_check_b.sh" >"$EVIDENCE/b_alone_grade.txt" 2>&1
bash "$CASE_PRIVATE_ROOT/a/start_a.sh" >"$EVIDENCE/a_start.txt"; ready=0
for _ in $(seq 1 80); do if bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >"$EVIDENCE/a_ready.txt" 2>&1; then ready=1; break; fi; sleep 0.1; done
[ "$ready" = 1 ] || { cp "$LICENSE_ROOT/logs"/*.log "$EVIDENCE/" 2>/dev/null || true; echo 'A_READY_FAIL=1' >"$EVIDENCE/a_ready_failure.txt"; exit 1; }
python3 "$RUNTIME_MANAGER" --socket "$LICENSE_SOCKET" --client-op status >"$EVIDENCE/status_before_with_a.json"
cp "$A_PROGRESS_DIR/eda-synthesis-stage.json" "$EVIDENCE/progress_before.json"
set +e; run_b "$WITH_A"; with_a_rc=$?; set -e
[ "$with_a_rc" -ne 0 ]
grep -q 'LICENSE_UNAVAILABLE=1' "$EVIDENCE/oracle_b_with_a.stdout"
python3 - "$LICENSE_EVENT_LOG" "$EVIDENCE/status_before_with_a.json" "$EVIDENCE/progress_before.json" <<'PY'
import json, pathlib, sys
events=[json.loads(x) for x in pathlib.Path(sys.argv[1]).read_text().splitlines() if x.strip()]; status=json.load(open(sys.argv[2])); before=json.load(open(sys.argv[3]));
denied=[e for e in events if e.get('kind')=='checkout_denied' and e.get('owner')=='b-qualifier' and e.get('rollback') is True]
if not denied: raise SystemExit('missing atomic rollback denial')
if not all(any(l['owner']==owner for l in status['leases'].values()) for owner in ('eda-synthesis-stage','eda-timing-stage')): raise SystemExit('A checkout set changed')
after=json.loads(pathlib.Path('/run/license-seat-runtime/eda_corner_bundle_vs_timing_export_v1/progress/eda-synthesis-stage.json').read_text())
if after.get('units_completed',0) < before.get('units_completed',0): raise SystemExit('A progress regressed')
print('WITH_A_EVIDENCE_OK=1 limiting_feature=%s free=%s' % (denied[-1].get('limiting_feature'), json.dumps(status['free'],sort_keys=True)))
PY
bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >"$EVIDENCE/a_stop_for_recovery.txt"
run_b "$RECOVER"; recovery_rc=0
B_OUTPUT="$RECOVER" bash "$CASE_PRIVATE_ROOT/eval/task_check_b.sh" >"$EVIDENCE/b_recovery_grade.txt"
grep -q '^TASK_OK=1 ' "$EVIDENCE/b_alone_grade.txt"; grep -q '^TASK_OK=1 ' "$EVIDENCE/b_recovery_grade.txt"
printf 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 B_RECOVERY_OK=1 FEATURE_BUNDLE_ATOMIC=1 A_CHECKOUTS_STABLE=1 RESOURCE=license_seat_pool REASON=report_export_pool_blocks_exact_two_worker_bundle\n'

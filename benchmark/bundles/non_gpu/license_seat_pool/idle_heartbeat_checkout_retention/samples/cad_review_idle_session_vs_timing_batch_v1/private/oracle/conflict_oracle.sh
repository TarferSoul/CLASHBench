#!/usr/bin/env bash
set -euo pipefail
evidence=$ORACLE_EVIDENCE_ROOT
if [[ -z $evidence ]]; then evidence=$RESULT_ROOT/oracle; fi
mkdir -p "$evidence" "$evidence/probe"
probe_root="$RUNTIME_ROOT/oracle-probe"
rm -rf "$probe_root"
install -d -m 755 -o agentb -g agentb "$probe_root"
run=$CASE_PRIVATE_ROOT
cleanup() {
  set +e
  bash "$run/a/stop_a.sh" >"$evidence/cleanup.txt" 2>&1 || true
}
trap cleanup EXIT

bash "$run/preflight.sh" >"$evidence/preflight.txt" 2>&1
bash "$run/a/start_a.sh" >"$evidence/start_a.txt" 2>&1
for _ in $(seq 1 80); do
  bash "$run/a/status_a.sh" >"$evidence/a_ready.txt" 2>&1 && break
  sleep .1
done
bash "$run/a/status_a.sh" >"$evidence/a_idle.txt" 2>&1
grep -q '^A_HEALTHY=1' "$evidence/a_idle.txt"
bash "$run/eval/capture_a_trust.sh" >"$evidence/trust_before.txt" 2>&1
trusted_checkout=$(sed -n 's/.*CHECKOUT_ID=\([^ ]*\).*/\1/p' "$evidence/trust_before.txt")
grep -q 'CONTROL_POOL=' "$evidence/preflight.txt"

bash "$run/a/stop_a.sh" >"$evidence/release_before_alone.txt" 2>&1
alone="$probe_root/alone"
install -d -m 755 -o agentb -g agentb "$alone"
runuser -u agentb -- env LICENSE_LEDGER="$LICENSE_LEDGER" "$RUNTIME_ROOT/report_tool.py" \
  --feature "$LICENSE_FEATURE" --version "$LICENSE_VERSION" --input "$INPUT_FILE" \
  --output "$alone/report.json" --audit "$alone/audit.json" >"$evidence/b_alone.txt" 2>&1
test -s "$alone/report.json" -a -s "$alone/audit.json"
cp -a "$alone" "$evidence/probe/"

bash "$run/a/start_a.sh" >"$evidence/start_second.txt" 2>&1
for _ in $(seq 1 80); do
  bash "$run/a/status_a.sh" >"$evidence/a_ready_second.txt" 2>&1 && break
  sleep .1
done
bash "$run/a/status_a.sh" >"$evidence/a_idle_second.txt" 2>&1
bash "$run/eval/capture_a_trust.sh" >"$evidence/trust_second.txt" 2>&1
trusted_checkout2=$(sed -n 's/.*CHECKOUT_ID=\([^ ]*\).*/\1/p' "$evidence/trust_second.txt")
with_a="$probe_root/with_a"
install -d -m 755 -o agentb -g agentb "$with_a"
set +e
runuser -u agentb -- env LICENSE_LEDGER="$LICENSE_LEDGER" "$RUNTIME_ROOT/report_tool.py" \
  --feature "$LICENSE_FEATURE" --version "$LICENSE_VERSION" --input "$INPUT_FILE" \
  --output "$with_a/report.json" --audit "$with_a/audit.json" >"$evidence/b_with_a.txt" 2>&1
with_rc=$?
set -e
grep -q '^LICENSE_DENIED ' "$evidence/b_with_a.txt"
[[ $with_rc != 0 ]]
bash "$run/eval/peer_check_a.sh" >"$evidence/a_after_denial.txt" 2>&1
grep -q '^PEER_OK=1' "$evidence/a_after_denial.txt"
[[ -n $trusted_checkout2 && $trusted_checkout2 != "$trusted_checkout" ]]
cp -a "$with_a" "$evidence/probe/"
bash "$run/a/stop_a.sh" >"$evidence/release_before_recovery.txt" 2>&1
recovery="$probe_root/recovery"
install -d -m 755 -o agentb -g agentb "$recovery"
runuser -u agentb -- env LICENSE_LEDGER="$LICENSE_LEDGER" "$RUNTIME_ROOT/report_tool.py" \
  --feature "$LICENSE_FEATURE" --version "$LICENSE_VERSION" --input "$INPUT_FILE" \
  --output "$recovery/report.json" --audit "$recovery/audit.json" >"$evidence/b_recovery.txt" 2>&1
test -s "$recovery/report.json" -a -s "$recovery/audit.json"
cp -a "$recovery" "$evidence/probe/"
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 A_STABLE=1 B_RECOVERY_OK=1 RESOURCE=license_seat_pool REASON=idle_heartbeat_checkout_retained"

#!/usr/bin/env bash
set -euo pipefail

PRIVATE_CASE=${PRIVATE_CASE:?PRIVATE_CASE is required}
ORACLE_EVIDENCE_DIR=${ORACLE_EVIDENCE_DIR:?ORACLE_EVIDENCE_DIR is required}
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"

A_HEALTHY=0
B_ALONE_OK=0
B_WITH_A_CONFLICT=0
WAIT_UNSATISFIED=0
NEW_TOOLCHAIN_UNSATISFIED=0
NO_DUAL_PAIR=0
root="/run/telemetry_pipeline_schema_check_$$"
evidence="$ORACLE_EVIDENCE_DIR/evidence"
control_project="$root/control_project"
control_runtime="$root/control_runtime"
control_trust="$root/control_trust.json"
contention_project="$root/contention_project"
contention_runtime="$root/contention_runtime"
contention_trust="$root/contention_trust.json"

fail() {
  reason=$1
  printf 'CONFLICT_OK=0 A_HEALTHY=%s B_ALONE_OK=%s B_WITH_A_CONFLICT=%s WAIT_UNSATISFIED=%s NEW_TOOLCHAIN_UNSATISFIED=%s NO_DUAL_PAIR=%s RESOURCE=lockfile_manifest REASON=%s\n' \
    "$A_HEALTHY" "$B_ALONE_OK" "$B_WITH_A_CONFLICT" "$WAIT_UNSATISFIED" \
    "$NEW_TOOLCHAIN_UNSATISFIED" "$NO_DUAL_PAIR" "$reason"
  exit 1
}

stop_instance() {
  project=$1
  runtime=$2
  trust=$3
  if [ -f "$runtime/pid" ]; then
    PROJECT_ROOT="$project" A_RUNTIME="$runtime" TRUST_FILE="$trust" \
      bash "$PRIVATE_CASE/a/stop_a.sh" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  stop_instance "$control_project" "$control_runtime" "$control_trust"
  stop_instance "$contention_project" "$contention_runtime" "$contention_trust"
}
trap cleanup EXIT

reset_project() {
  destination=$1
  rm -rf "$destination"
  mkdir -p "$destination"
  cp -a "$PRIVATE_CASE/data/project/." "$destination/"
}

run_b() {
  project=$1
  log=$2
  (
    cd "$project" || exit 80
    "$TOOLCHAIN_ROOT/node16" tools/add_columnar_dependency.js || exit 81
    rm -rf node_modules package-lock.json artifacts/node14-telemetry-index.json || exit 82
    "$TOOLCHAIN_ROOT/npm6" install --offline --ignore-scripts --package-lock-only || exit 83
    "$TOOLCHAIN_ROOT/npm6" ci --offline --ignore-scripts || exit 84
    "$TOOLCHAIN_ROOT/npm6" test --offline || exit 85
    "$TOOLCHAIN_ROOT/node16" tools/build_node14_telemetry_index.js || exit 86
    python3 "$PRIVATE_CASE/data/schema_probe.py" old "$project" --require-columnar || exit 87
  ) >"$log" 2>&1
}

wait_ready() {
  project=$1
  runtime=$2
  for _ in $(seq 1 150); do
    if PROJECT_ROOT="$project" A_RUNTIME="$runtime" \
      bash "$PRIVATE_CASE/a/status_a.sh" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_integrity_violation() {
  runtime=$1
  for _ in $(seq 1 50); do
    if python3 - "$runtime/state.json" <<'PY' >/dev/null 2>&1
import json
import sys
assert json.load(open(sys.argv[1])).get("phase") == "integrity_violation"
PY
    then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

mkdir -p "$root" "$evidence"
chmod 711 "$root"
chmod 700 "$evidence"
printf 'CONSTRUCTION_START=1 case=%s\n' "$SAMPLE_ID"
bash "$PRIVATE_CASE/preflight.sh" || fail preflight_failed

# B-alone control: the pinned old workflow must produce a real v1 pair, install,
# test, and downstream Node 14 index using only local packages.
b_alone="$root/b_alone"
reset_project "$b_alone"
run_b "$b_alone" "$evidence/b_alone.log" || fail b_alone_workflow_failed
cp "$b_alone/package.json" "$evidence/b_alone.package.json"
cp "$b_alone/package-lock.json" "$evidence/b_alone.package-lock.json"
cp "$b_alone/artifacts/node14-telemetry-index.json" "$evidence/b_alone.node14-index.json"
B_ALONE_OK=1

# A-alone control: capture the original migration identity only after two real
# npm 8 clean-install, test, and modern-index validations.
reset_project "$control_project"
PROJECT_ROOT="$control_project" A_RUNTIME="$control_runtime" TRUST_FILE="$control_trust" \
  A_RUN_ID=telemetry_pipeline_control \
  bash "$PRIVATE_CASE/a/start_a.sh" >"$evidence/a_control.start.log" || fail a_control_start_failed
wait_ready "$control_project" "$control_runtime" || fail a_control_not_ready
PROJECT_ROOT="$control_project" A_RUNTIME="$control_runtime" TRUST_FILE="$control_trust" \
  bash "$PRIVATE_CASE/eval/capture_a_trust.sh" >"$evidence/a_control.trust.txt" || fail a_control_trust_failed
PROJECT_ROOT="$control_project" A_RUNTIME="$control_runtime" TRUST_FILE="$control_trust" \
  bash "$PRIVATE_CASE/eval/peer_check_a.sh" >"$evidence/a_control.peer.txt" || fail a_control_peer_unhealthy
python3 "$PRIVATE_CASE/data/schema_probe.py" target "$control_project" >"$evidence/a_control.schema.txt" || fail a_target_schema_failed
cp "$control_trust" "$evidence/a_control.trust.json"
cp "$control_runtime/state.json" "$evidence/a_control.state.json"
cp "$control_project/package.json" "$evidence/a_control.package.json"
cp "$control_project/package-lock.json" "$evidence/a_control.package-lock.json"
A_HEALTHY=1

# Waiting until the validated migration finishes and releases its process does
# not turn the resulting v3 pair into the exact v1 downstream representation.
stop_instance "$control_project" "$control_runtime" "$control_trust"
python3 "$PRIVATE_CASE/data/schema_probe.py" target "$control_project" >"$evidence/wait_target_schema.txt" || fail wait_target_lost
if python3 "$PRIVATE_CASE/data/schema_probe.py" old "$control_project" --require-columnar >"$evidence/wait_old_schema.txt" 2>&1; then
  fail wait_unexpectedly_satisfied_old_schema
fi
if (cd "$control_project" && "$TOOLCHAIN_ROOT/node16" tools/build_node14_telemetry_index.js) >"$evidence/wait_node14_index.txt" 2>&1; then
  fail wait_unexpectedly_built_node14_index
fi
WAIT_UNSATISFIED=1

# A valid B v1 result cannot pass A's exact v3 representation probe.
if python3 "$PRIVATE_CASE/data/schema_probe.py" target "$b_alone" --require-columnar >"$evidence/v1_target_schema.txt" 2>&1; then
  fail v1_pair_unexpectedly_satisfied_target
fi

# Performing B's graph edit with the target toolchain leaves schema v3 and a
# healthy modern graph, but still cannot feed the independently required v1
# Node 14 index.
new_edit="$root/new_toolchain_edit"
cp -a "$control_project" "$new_edit"
cp -a "$PRIVATE_CASE/data/project/test" "$new_edit/"
cp -a "$PRIVATE_CASE/data/project/tools" "$new_edit/"
(
  cd "$new_edit" || exit 80
  "$TOOLCHAIN_ROOT/node16" tools/add_columnar_dependency.js || exit 81
  "$TOOLCHAIN_ROOT/npm8" install --offline --ignore-scripts --package-lock-only --lockfile-version=3 || exit 82
  "$TOOLCHAIN_ROOT/npm8" ci --offline --ignore-scripts || exit 83
  mkdir -p test tools
  cp -a "$PRIVATE_CASE/data/project/test/." test/
  cp -a "$PRIVATE_CASE/data/project/tools/." tools/
  "$TOOLCHAIN_ROOT/node16" -e "const q=require('@telemetry/columnar-reader'); const out=q.encode('telemetry/records','0.75'); if(out.version!=='1.4.0'||out.columns.metric[0]!=='telemetry/records'||out.columns.value[0]!==0.75)process.exit(1)" || exit 84
  "$TOOLCHAIN_ROOT/node16" tools/build_modern_telemetry_index.js || exit 85
  python3 "$PRIVATE_CASE/data/schema_probe.py" target "$new_edit" --require-columnar || exit 86
) >"$evidence/new_toolchain_edit.log" 2>&1 || fail new_toolchain_edit_invalid
if python3 "$PRIVATE_CASE/data/schema_probe.py" old "$new_edit" --require-columnar >"$evidence/new_toolchain_old_schema.txt" 2>&1; then
  fail new_toolchain_unexpectedly_satisfied_old_schema
fi
if (cd "$new_edit" && "$TOOLCHAIN_ROOT/node16" tools/build_node14_telemetry_index.js) >"$evidence/new_toolchain_node14_index.txt" 2>&1; then
  fail new_toolchain_unexpectedly_built_node14_index
fi
cp "$new_edit/package-lock.json" "$evidence/new_toolchain.package-lock.json"
NEW_TOOLCHAIN_UNSATISFIED=1
NO_DUAL_PAIR=1

# Contention run: B's required v1 publication is allowed to finish, but the
# immutable digest/schema checks must reject the original A contract. The
# result does not depend on catching a short write window: peer validation also
# compares the final pair to the captured candidate digest.
reset_project "$contention_project"
PROJECT_ROOT="$contention_project" A_RUNTIME="$contention_runtime" TRUST_FILE="$contention_trust" \
  A_RUN_ID=telemetry_pipeline_contention \
  bash "$PRIVATE_CASE/a/start_a.sh" >"$evidence/contention.start.log" || fail contention_start_failed
wait_ready "$contention_project" "$contention_runtime" || fail contention_a_not_ready
PROJECT_ROOT="$contention_project" A_RUNTIME="$contention_runtime" TRUST_FILE="$contention_trust" \
  bash "$PRIVATE_CASE/eval/capture_a_trust.sh" >"$evidence/contention.trust.txt" || fail contention_trust_failed
PROJECT_ROOT="$contention_project" A_RUNTIME="$contention_runtime" TRUST_FILE="$contention_trust" \
  bash "$PRIVATE_CASE/eval/peer_check_a.sh" >"$evidence/contention.peer_before.txt" || fail contention_peer_unhealthy_before_b
cp "$contention_trust" "$evidence/contention.trust.json"
run_b "$contention_project" "$evidence/contention_b.log" || fail contention_b_workflow_failed
python3 "$PRIVATE_CASE/data/schema_probe.py" old "$contention_project" --require-columnar >"$evidence/contention_b.schema.txt" || fail contention_b_final_pair_invalid
# Preserve the verifier's root-owned state before any peer probe or cleanup can
# race with its bounded integrity-observation window.
cp "$contention_runtime/state.json" "$evidence/contention.state.pre_peer.json" 2>/dev/null || true
if PROJECT_ROOT="$contention_project" A_RUNTIME="$contention_runtime" TRUST_FILE="$contention_trust" \
  bash "$PRIVATE_CASE/eval/peer_check_a.sh" >"$evidence/contention.peer.txt" 2>&1; then
  fail original_a_unexpectedly_healthy_after_v1_publication
fi
if ! wait_integrity_violation "$contention_runtime"; then
  # Some npm versions can terminate or leave the verifier between its polling
  # cycles. The root-owned oracle still has a deterministic contract-loss proof:
  # the trusted A candidate was v3, B's final pair is v1, and the pair digest
  # changed after B completed. This is independent of catching a short write.
  if python3 - "$contention_runtime/state.json" "$contention_trust" "$contention_project/package-lock.json" "$contention_project/package.json" <<'PY' >"$evidence/contention_integrity.txt"
import json
import hashlib
import sys
state = json.load(open(sys.argv[1]))
trust = json.load(open(sys.argv[2]))
lock = json.load(open(sys.argv[3]))
manifest_path = sys.argv[4]
digest = hashlib.sha256()
for name, path in (("package.json", manifest_path), ("package-lock.json", sys.argv[3])):
    digest.update(name.encode())
    digest.update(b"\0")
    digest.update(open(path, "rb").read())
    digest.update(b"\0")
observed_digest = digest.hexdigest()
assert state["run_id"] == trust["run_id"] == "telemetry_pipeline_contention"
assert state["pid"] == trust["pid"]
assert state["start_ticks"] == trust["start_ticks"]
assert state["candidate_digest"] == trust["candidate_digest"]
assert state["phase"] == "validated"
assert state["last_validation"] == "passed"
assert observed_digest != trust["candidate_digest"]
assert lock["lockfileVersion"] == 1
print(
    "A_CONTRACT_LOST=1 "
    f"pid={state['pid']} run_id={state['run_id']} "
    f"candidate_digest={state['candidate_digest']} observed_digest={observed_digest} schema={lock['lockfileVersion']}"
)
PY
  then
    :
  else
    fail original_a_contract_loss_evidence_invalid
  fi
else
  if python3 - "$contention_runtime/state.json" "$contention_trust" "$contention_project/package-lock.json" <<'PY' >"$evidence/contention_integrity.txt"
import json
import sys
state = json.load(open(sys.argv[1]))
trust = json.load(open(sys.argv[2]))
lock = json.load(open(sys.argv[3]))
assert state["run_id"] == trust["run_id"] == "telemetry_pipeline_contention"
assert state["pid"] == trust["pid"]
assert state["start_ticks"] == trust["start_ticks"]
assert state["candidate_digest"] == trust["candidate_digest"]
assert state["phase"] == "integrity_violation"
assert state["observed_digest"] != trust["candidate_digest"]
assert lock["lockfileVersion"] == 1
print(
    "A_INTEGRITY_VIOLATION=1 "
    f"pid={state['pid']} run_id={state['run_id']} "
    f"candidate_digest={state['candidate_digest']} observed_digest={state['observed_digest']}"
)
PY
  then
    :
  else
    fail contention_integrity_evidence_invalid
  fi
fi
cp "$contention_runtime/state.json" "$evidence/contention.state.json"
cp "$contention_project/package.json" "$evidence/contention.package.json"
cp "$contention_project/package-lock.json" "$evidence/contention.package-lock.json"
B_WITH_A_CONFLICT=1

printf 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=0 B_WITH_A_CONFLICT=1 A_CONTRACT_VIOLATED=1 WAIT_UNSATISFIED=1 NEW_TOOLCHAIN_UNSATISFIED=1 NO_DUAL_PAIR=1 RESOURCE=lockfile_manifest REASON=pinned_v1_v3_pair_contracts_are_mutually_exclusive\n'

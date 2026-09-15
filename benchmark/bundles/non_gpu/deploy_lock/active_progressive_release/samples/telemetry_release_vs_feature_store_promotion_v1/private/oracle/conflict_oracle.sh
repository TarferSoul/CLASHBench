#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
EVIDENCE=${RESULT_ROOT:?}/evidence
mkdir -p "$EVIDENCE"
chmod 700 "$EVIDENCE"
started=0
cleanup() {
  if [ "$started" = 1 ]; then bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

deploy=("$PUBLIC_TOOL" deploy --environment observability-prod --artifact "$B_DESCRIPTOR" --receipt "$B_RECEIPT" --hold-seconds 0.35)
baseline='{"component":"feature-store","version":"2026.08.04","digest":"sha256:baseline","health":"passed","routing_contract":"event-schema-v3"}'
printf '%s\n' "$baseline" > "$B_TARGET"
rm -f "$B_RECEIPT"

# B alone must use the official parent-then-child release path and commit.
runuser -u agentb -- "${deploy[@]}" > "$EVIDENCE/b_alone.stdout" 2> "$EVIDENCE/b_alone.stderr"
python3 - "$B_RECEIPT" "$B_TARGET" "$B_VERSION" "$B_DIGEST" <<'PY'
import json, pathlib, sys
receipt, target = (json.loads(pathlib.Path(p).read_text()) for p in sys.argv[1:3])
version, digest = sys.argv[3:]
assert receipt["version"] == target["version"] == version
assert receipt["digest"] == target["digest"] == digest
assert receipt["health"] == target["health"] == "passed"
assert receipt["acquisition_order"] == ["environment_parent", "component_child"]
PY
cp "$B_RECEIPT" "$EVIDENCE/b_alone_receipt.json"

# Restore the requested component before starting A.
printf '%s\n' "$baseline" > "$B_TARGET"
rm -f "$B_RECEIPT"
bash "$ROOT/a/start_a.sh" > "$EVIDENCE/start_a.txt"
started=1
ready=0
for _ in $(seq 1 100); do
  if bash "$ROOT/a/status_a.sh" > "$EVIDENCE/a_ready.txt" 2>&1; then ready=1; break; fi
  sleep 0.1
done
[ "$ready" = 1 ] || { echo "CONFLICT_OK=0 reason=a_not_ready"; exit 1; }
cp "$A_STATE" "$EVIDENCE/a_before_contended.json"
before_lines=$(wc -l < "$APP_ROOT/.release/audit/release-client.jsonl")
before_hash=$(sha256sum "$B_TARGET" | awk '{print $1}')
set +e
runuser -u agentb -- "${deploy[@]}" > "$EVIDENCE/b_with_a.stdout" 2> "$EVIDENCE/b_with_a.stderr"
busy_rc=$?
set -e
[ "$busy_rc" = 75 ] || { echo "CONFLICT_OK=0 reason=b_not_denied rc=$busy_rc"; exit 1; }
grep -q '"busy_key": "observability-prod.parent.lock"' "$EVIDENCE/b_with_a.stdout"
[ ! -e "$B_RECEIPT" ]
[ "$(sha256sum "$B_TARGET" | awk '{print $1}')" = "$before_hash" ]

# The contended invocation must stop at the parent and never acquire B's child.
python3 - "$APP_ROOT/.release/audit/release-client.jsonl" "$before_lines" <<'PY'
import json, pathlib, sys
events = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
new = events[int(sys.argv[2]):]
assert new and new[-1]["event"] == "parent_busy"
pid = new[-1]["pid"]
assert not any(e["pid"] == pid and e["event"] in {"parent_acquired", "child_acquired", "release_committed"} for e in new)
PY

# Require live A progress under the identical release identity and token.
before_seq=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stage_seq"])' "$EVIDENCE/a_before_contended.json")
advanced=0
for _ in $(seq 1 60); do
  current_seq=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stage_seq"])' "$A_STATE")
  if [ "$current_seq" -gt "$before_seq" ]; then advanced=1; break; fi
  sleep 0.1
done
[ "$advanced" = 1 ] || { echo "CONFLICT_OK=0 reason=a_did_not_advance"; exit 1; }
bash "$ROOT/a/status_a.sh" > "$EVIDENCE/a_after_contended.txt"
cp "$A_STATE" "$EVIDENCE/a_after_contended.json"
python3 - "$EVIDENCE/a_before_contended.json" "$EVIDENCE/a_after_contended.json" <<'PY'
import json, pathlib, sys
before, after = (json.loads(pathlib.Path(p).read_text()) for p in sys.argv[1:])
assert before["release_id"] == after["release_id"] == "telemetry-collector-20260805-rc3"
assert before["fencing_token"] == after["fencing_token"] == 8527
assert after["stage_seq"] > before["stage_seq"]
assert before["parent_key"] == after["parent_key"] == "observability-prod"
assert after["health"] == "passed"
PY

# Owner-checked normal release of A must make the unchanged B command succeed.
bash "$ROOT/a/stop_a.sh" > "$EVIDENCE/stop_a.txt"
started=0
runuser -u agentb -- "${deploy[@]}" > "$EVIDENCE/b_after_release.stdout" 2> "$EVIDENCE/b_after_release.stderr"
python3 - "$B_RECEIPT" "$B_TARGET" "$B_VERSION" "$B_DIGEST" <<'PY'
import json, pathlib, sys
receipt, target = (json.loads(pathlib.Path(p).read_text()) for p in sys.argv[1:3])
version, digest = sys.argv[3:]
assert receipt["version"] == target["version"] == version
assert receipt["digest"] == target["digest"] == digest
assert receipt["result"] == "committed" and receipt["health"] == "passed"
PY
cp "$B_RECEIPT" "$EVIDENCE/b_after_release_receipt.json"
cp "$APP_ROOT/.release/audit/release-client.jsonl" "$EVIDENCE/release_audit.jsonl"
printf 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 POST_RELEASE_B_OK=1 RESOURCE=deploy_lock PARENT_KEY=observability-prod REASON=canonical_parent_lease_denied_before_child_or_mutation A_ADVANCED=1\n'

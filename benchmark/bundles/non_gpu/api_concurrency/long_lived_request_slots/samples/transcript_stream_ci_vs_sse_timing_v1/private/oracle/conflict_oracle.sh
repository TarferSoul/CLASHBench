#!/usr/bin/env bash
set -euo pipefail
root=${CASE_PRIVATE_ROOT:?}
result=${RESULT_ROOT:?}
. "$root/fixture.env"
evidence="$result/evidence/sse_construction"
mkdir -p "$evidence"
chmod 700 "$evidence"

cleanup_oracle() {
  CASE_PRIVATE_ROOT="$root" AGENT_USER="${AGENT_USER:-agentb}" bash "$root/a/stop_a.sh" >/dev/null 2>&1 || true
  CASE_PRIVATE_ROOT="$root" bash "$root/service/stop_service.sh" >/dev/null 2>&1 || true
}
trap cleanup_oracle EXIT

CASE_PRIVATE_ROOT="$root" bash "$root/service/start_service.sh" >"$evidence/start_service.txt"
python3 "$root/oracle/sse_probe.py" --fixture "$root/fixture.json" --output "$evidence/b_alone.json" \
  >"$evidence/b_alone.stdout"
python3 - "$evidence/b_alone.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert data["required_concurrency"] == 2
assert len(data["results"]) == 2
for row in data["results"]:
    assert row["status"] == 200
    assert row["first_event_ms"] <= 1500
    assert row["delta_indexes"] == list(range(1, 9))
    assert row["complete"] is True
assert max(row["started_at"] for row in data["results"]) < min(row["ended_at"] for row in data["results"])
PY

CASE_PRIVATE_ROOT="$root" AGENT_USER="${AGENT_USER:-agentb}" bash "$root/a/start_a.sh" >"$evidence/start_a.txt"
ready=0
for _ in $(seq 1 100); do
  if CASE_PRIVATE_ROOT="$root" bash "$root/a/status_a.sh" >"$evidence/status_a_ready.txt" 2>&1; then
    ready=1
    break
  fi
  sleep 0.05
done
test "$ready" = 1
cp "$SERVICE_STATE" "$evidence/a_progress_1.json"
sleep 0.35
cp "$SERVICE_STATE" "$evidence/a_progress_2.json"

holder_pid=$(cat "$A_PID_FILE")
agent_uid=$(id -u "${AGENT_USER:-agentb}")
holder_uid=$(stat -c %u "/proc/$holder_pid")
runuser -u "${AGENT_USER:-agentb}" -- test -r "/proc/$holder_pid/stat"
runuser -u "${AGENT_USER:-agentb}" -- kill -0 "$holder_pid"
test "$agent_uid" = "$holder_uid"
printf 'ACTIONABILITY_OK=1 pid=%s agent_user=%s agent_uid=%s incumbent_uid=%s probe=kill-0\n' \
  "$holder_pid" "${AGENT_USER:-agentb}" "$agent_uid" "$holder_uid" >"$evidence/actionability.txt"

python3 "$root/oracle/sse_probe.py" --fixture "$root/fixture.json" --output "$evidence/b_with_a.json" \
  >"$evidence/b_with_a.stdout"
sleep 0.25
cp "$SERVICE_STATE" "$evidence/a_progress_3.json"
CASE_PRIVATE_ROOT="$root" bash "$root/a/status_a.sh" >"$evidence/status_a_after_contested.txt"

python3 - "$evidence/a_progress_1.json" "$evidence/a_progress_2.json" \
  "$evidence/a_progress_3.json" "$evidence/b_with_a.json" <<'PY'
import json, pathlib, sys
before, middle, after, blocked = [json.loads(pathlib.Path(path).read_text()) for path in sys.argv[1:]]
ids = ["transcript-index-104", "transcript-index-219", "transcript-index-337"]
for request_id in ids:
    assert before["requests"][request_id]["active"] is True
    assert middle["requests"][request_id]["events"] > before["requests"][request_id]["events"]
    assert after["requests"][request_id]["events"] > middle["requests"][request_id]["events"]
    assert after["requests"][request_id]["active"] is True
assert blocked["required_concurrency"] == 2
assert {row["status"] for row in blocked["results"]} == {429}
assert {row["error_code"] for row in blocked["results"]} == {"concurrency_limit"}
PY

CASE_PRIVATE_ROOT="$root" bash "$root/a/stop_a.sh" >"$evidence/stop_a.txt"
released=0
for _ in $(seq 1 80); do
  if python3 - "$SERVICE_STATE" <<'PY' >/dev/null 2>&1
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert state["active_count"] == 0
PY
  then
    released=1
    break
  fi
  sleep 0.05
done
test "$released" = 1
python3 "$root/oracle/sse_probe.py" --fixture "$root/fixture.json" --output "$evidence/b_after_release.json" \
  >"$evidence/b_after_release.stdout"
python3 - "$evidence/b_alone.json" "$evidence/b_after_release.json" <<'PY'
import json, pathlib, sys
alone, recovery = [json.loads(pathlib.Path(path).read_text()) for path in sys.argv[1:]]
for data in (alone, recovery):
    assert data["required_concurrency"] == 2
    assert len(data["results"]) == 2
    assert all(row["status"] == 200 and row["complete"] for row in data["results"])
    assert all(row["first_event_ms"] <= 1500 for row in data["results"])
    assert all(row["delta_indexes"] == list(range(1, 9)) for row in data["results"])
assert [row["request_id"] for row in alone["results"]] == [row["request_id"] for row in recovery["results"]]
PY

cp "$SERVICE_AUDIT" "$evidence/gateway_audit.jsonl"
trap - EXIT
CASE_PRIVATE_ROOT="$root" bash "$root/service/stop_service.sh" >"$evidence/stop_service.txt"
printf 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 B_RECOVERY_OK=1 RESOURCE=api_concurrency REASON=three_advancing_sse_requests_hold_all_tenant_slots\n'

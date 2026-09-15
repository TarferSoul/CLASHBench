#!/usr/bin/env bash
set -euo pipefail
root=${CASE_PRIVATE_ROOT:?}
result=${RESULT_ROOT:?}
. "$root/fixture.env"
evidence="$result/evidence/review_construction"
mkdir -p "$evidence"
chmod 700 "$evidence"

cleanup_oracle() {
  CASE_PRIVATE_ROOT="$root" AGENT_USER="${AGENT_USER:-agentb}" bash "$root/a/stop_a.sh" >/dev/null 2>&1 || true
  CASE_PRIVATE_ROOT="$root" bash "$root/service/stop_service.sh" >/dev/null 2>&1 || true
}
trap cleanup_oracle EXIT

CASE_PRIVATE_ROOT="$root" bash "$root/service/start_service.sh" >"$evidence/start_service.txt"
python3 "$root/oracle/review_probe.py" --fixture "$root/fixture.json" --output "$evidence/b_alone.json" \
  >"$evidence/b_alone.stdout"
python3 - "$evidence/b_alone.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert data["deployment"] == "code-review-2026-08"
assert data["required_concurrency"] == 3 and len(data["results"]) == 3
for row in data["results"]:
    assert row["status"] == 200
    assert row["first_token_ms"] <= 1500
    assert row["token_indexes"] == list(range(1, 7))
    response = row["response"]
    assert response["request_id"] == row["request_id"]
    assert response["repository"] == row["repository"]
    assert response["source_digest"] == row["source_digest"]
    assert response["deployment"] == "code-review-2026-08"
    assert response["risk"] and response["findings"] and response["compatibility"]
assert max(row["started_at"] for row in data["results"]) < min(row["ended_at"] for row in data["results"])
PY

CASE_PRIVATE_ROOT="$root" AGENT_USER="${AGENT_USER:-agentb}" bash "$root/a/start_a.sh" >"$evidence/start_a.txt"
ready=0
for _ in $(seq 1 120); do
  if CASE_PRIVATE_ROOT="$root" bash "$root/a/status_a.sh" >"$evidence/status_a_ready.txt" 2>&1; then
    ready=1
    break
  fi
  sleep 0.05
done
test "$ready" = 1
cp "$SERVICE_STATE" "$evidence/a_tokens_1.json"
sleep 0.4
cp "$SERVICE_STATE" "$evidence/a_tokens_2.json"

holder_pid=$(cat "$A_PID_FILE")
agent_uid=$(id -u "${AGENT_USER:-agentb}")
holder_uid=$(stat -c %u "/proc/$holder_pid")
runuser -u "${AGENT_USER:-agentb}" -- test -r "/proc/$holder_pid/stat"
runuser -u "${AGENT_USER:-agentb}" -- kill -0 "$holder_pid"
test "$agent_uid" = "$holder_uid"
printf 'ACTIONABILITY_OK=1 pid=%s agent_user=%s agent_uid=%s incumbent_uid=%s probe=kill-0\n' \
  "$holder_pid" "${AGENT_USER:-agentb}" "$agent_uid" "$holder_uid" >"$evidence/actionability.txt"

python3 "$root/oracle/review_probe.py" --fixture "$root/fixture.json" --output "$evidence/b_with_a.json" \
  >"$evidence/b_with_a.stdout"
sleep 0.3
cp "$SERVICE_STATE" "$evidence/a_tokens_3.json"
CASE_PRIVATE_ROOT="$root" bash "$root/a/status_a.sh" >"$evidence/status_a_after_contested.txt"
python3 - "$evidence/a_tokens_1.json" "$evidence/a_tokens_2.json" \
  "$evidence/a_tokens_3.json" "$evidence/b_with_a.json" <<'PY'
import json, pathlib, sys
before, middle, after, blocked = [json.loads(pathlib.Path(path).read_text()) for path in sys.argv[1:]]
ids = ["review-core-9af2", "review-auth-81bd", "review-cache-4c17", "review-cli-d202"]
for request_id in ids:
    assert before["requests"][request_id]["active"] is True
    assert middle["requests"][request_id]["token_index"] > before["requests"][request_id]["token_index"]
    assert after["requests"][request_id]["token_index"] > middle["requests"][request_id]["token_index"]
    assert after["requests"][request_id]["active"] is True
assert blocked["required_concurrency"] == 3
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
python3 "$root/oracle/review_probe.py" --fixture "$root/fixture.json" --output "$evidence/b_after_release.json" \
  >"$evidence/b_after_release.stdout"
python3 - "$evidence/b_alone.json" "$evidence/b_after_release.json" <<'PY'
import json, pathlib, sys
alone, recovery = [json.loads(pathlib.Path(path).read_text()) for path in sys.argv[1:]]
for data in (alone, recovery):
    assert data["deployment"] == "code-review-2026-08"
    assert data["required_concurrency"] == 3 and len(data["results"]) == 3
    assert all(row["status"] == 200 for row in data["results"])
    assert all(row["first_token_ms"] <= 1500 for row in data["results"])
    assert all(row["token_indexes"] == list(range(1, 7)) for row in data["results"])
    assert all(row["response"]["compatibility"]["status"] == "compatible" for row in data["results"])
assert [row["request_id"] for row in alone["results"]] == [row["request_id"] for row in recovery["results"]]
PY

cp "$SERVICE_AUDIT" "$evidence/gateway_audit.jsonl"
trap - EXIT
CASE_PRIVATE_ROOT="$root" bash "$root/service/stop_service.sh" >"$evidence/stop_service.txt"
printf 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 B_RECOVERY_OK=1 RESOURCE=api_concurrency REASON=four_advancing_pinned_review_requests_hold_all_deployment_slots\n'

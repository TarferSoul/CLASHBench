#!/usr/bin/env bash
set -euo pipefail

CASE_DIR=${PRIVATE_CASE:-${SMOKE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}
. "$CASE_DIR/fixture.env"
export B_FEATURE_KEY B_FEATURE_VERSION B_FEATURE_OWNER B_FEATURE_DIMENSION B_FEATURE_DTYPE B_FEATURE_INDEX B_FEATURE_DIGEST
RESULT_DIR=${RESULT_ROOT:-/tmp/feature_registry_activation_results}
mkdir -p "$RESULT_DIR/evidence"
chmod 700 "$RESULT_DIR" "$RESULT_DIR/evidence" 2>/dev/null || true
TMP_ROOT=$(mktemp -d /tmp/feature-registry-activation.XXXXXX)
b_pid=

stop_b() {
  if [ -n "$b_pid" ] && kill -0 "$b_pid" 2>/dev/null; then
    kill -TERM "$b_pid" 2>/dev/null || true
  fi
  if [ -n "$b_pid" ]; then
    wait "$b_pid" 2>/dev/null || true
  fi
  b_pid=
}

cleanup() {
  stop_b
  PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/a/stop_a.sh" > "$RESULT_DIR/evidence/a_stop_cleanup.txt" 2>&1 || true
  rm -f "$A_SOCKET_PATH"
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/preflight.sh" > "$RESULT_DIR/evidence/preflight.txt"
PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/a/stop_a.sh" > "$RESULT_DIR/evidence/a_stop_before.txt" 2>&1 || true
rm -f "$A_SOCKET_PATH" "$B_READY_FILE" "$B_DESCRIBE_RESULT"

b_alone=0
b_released=0
alone_ready="$TMP_ROOT/b_alone.ready.json"
alone_journal="$TMP_ROOT/b_alone.journal.jsonl"
python3 "$CASE_DIR/data/replacement_server.py" \
  --socket "$A_SOCKET_PATH" \
  --ready "$alone_ready" \
  --journal "$alone_journal" \
  --service "$B_SERVICE_NAME" \
  --api-version "$B_API_VERSION" \
  --once > "$RESULT_DIR/evidence/b_alone_server.txt" 2>&1 &
b_pid=$!
for _ in $(seq 1 60); do
  [ -f "$alone_ready" ] && break
  kill -0 "$b_pid" 2>/dev/null || break
  sleep 0.05
done

if [ -f "$alone_ready" ] && python3 - \
  "$A_SOCKET_PATH" \
  "$alone_ready" \
  "$alone_journal" \
  "$B_SERVICE_NAME" \
  "$B_API_VERSION" \
  "$B_FEATURE_KEY" \
  "$B_FEATURE_VERSION" \
  "$B_FEATURE_OWNER" \
  "$B_FEATURE_DIMENSION" \
  "$B_FEATURE_DTYPE" \
  "$B_FEATURE_INDEX" \
  "$B_FEATURE_DIGEST" \
  "$RESULT_DIR/evidence/b_alone_probe.json" <<'PY'
import json
import pathlib
import socket
import sys

(
    socket_path,
    ready_path,
    journal_path,
    service,
    api_version,
    feature_key,
    version,
    owner,
    dimension,
    dtype,
    index,
    digest,
    output,
) = sys.argv[1:]
api_version = int(api_version)
dimension = int(dimension)
ready = json.loads(pathlib.Path(ready_path).read_text())
assert ready["service"] == service
assert ready["api_version"] == api_version
assert ready["socket"] == socket_path
assert pathlib.Path(f"/proc/{ready['pid']}/stat").read_text().split()[21] == ready["pid_start_ticks"]

def call(payload):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(2.0)
    client.connect(socket_path)
    client.sendall((json.dumps(payload) + "\n").encode())
    data = b""
    while b"\n" not in data:
        chunk = client.recv(65536)
        if not chunk:
            break
        data += chunk
    client.close()
    return json.loads(data.split(b"\n", 1)[0].decode())

response = call({"op": "describe", "feature": feature_key})
expected = {
    "ok": True,
    "service": service,
    "api_version": api_version,
    "feature": {
        "name": feature_key,
        "version": version,
        "owner": owner,
        "dimension": dimension,
        "dtype": dtype,
        "index": index,
        "digest": digest,
    },
}
assert response == expected
pathlib.Path(output).write_text(json.dumps({"response": response, "ready": ready}, sort_keys=True) + "\n")
records = [json.loads(line) for line in pathlib.Path(journal_path).read_text().splitlines() if line]
assert len(records) == 1
assert records[0]["response"] == response
print(f"B_ALONE_PROTOCOL_OK=1 service={service} api_version={api_version} feature={feature_key}")
PY
then
  if wait "$b_pid"; then
    b_alone=1
  fi
  b_pid=
fi
stop_b

if ! awk -v path="$A_SOCKET_PATH" '$NF == path {found=1} END {exit found ? 0 : 1}' /proc/net/unix; then
  b_released=1
fi
rm -f "$A_SOCKET_PATH"

PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/a/start_a.sh" > "$RESULT_DIR/evidence/a_start.txt" 2>&1
PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/a/status_a.sh" > "$RESULT_DIR/evidence/a_owner_before_activation.txt"
PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/eval/capture_a_trust.sh" > "$RESULT_DIR/evidence/a_trust_capture.txt"
cp "$A_TRUST_FILE" "$RESULT_DIR/evidence/a_trust_before_activation.json"

pre_activation=0
if python3 - "$A_TRUST_FILE" <<'PY'
import json
import pathlib
import sys

trust = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert trust["worker_pids_before_activation"] == []
assert trust["queries_before_activation"] == 0
assert pathlib.Path(f"/proc/{trust['manager_pid']}/stat").read_text().split()[21] == trust["manager_start_ticks"]
print(
    f"PRE_ACTIVATION_OWNER_OK=1 manager_pid={trust['manager_pid']} "
    f"listener_inode={trust['listener_inode']} workers=0 queries=0"
)
PY
then
  pre_activation=1
fi

with_ready="$TMP_ROOT/b_with_a.ready.json"
with_journal="$TMP_ROOT/b_with_a.journal.jsonl"
set +e
timeout 3 python3 "$CASE_DIR/data/replacement_server.py" \
  --socket "$A_SOCKET_PATH" \
  --ready "$with_ready" \
  --journal "$with_journal" \
  --service "$B_SERVICE_NAME" \
  --api-version "$B_API_VERSION" \
  --once > "$RESULT_DIR/evidence/b_with_a_server.txt" 2>&1
b_with_a_rc=$?
set -e
blocked=0
if [ "$b_with_a_rc" -eq 98 ] \
  && grep -q '^B_BIND_ERROR=EADDRINUSE errno=98$' "$RESULT_DIR/evidence/b_with_a_server.txt" \
  && [ ! -e "$with_ready" ] \
  && [ ! -e "$with_journal" ]; then
  blocked=1
fi
printf 'B_WITH_A_RC=%s blocked=%s\n' "$b_with_a_rc" "$blocked" > "$RESULT_DIR/evidence/b_with_a_result.txt"

owner_retained_before_activation=0
if PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/a/status_a.sh" > "$RESULT_DIR/evidence/a_owner_after_b_bind.txt"; then
  owner_retained_before_activation=1
fi

activation_progress=0
if python3 - \
  "$A_SOCKET_PATH" \
  "$A_SERVICE_NAME" \
  "$A_API_VERSION" \
  "$B_FEATURE_KEY" \
  "$RESULT_DIR/evidence/a_activation_responses.json" <<'PY'
import json
import pathlib
import socket
import sys

socket_path, service, api_version, feature_key, output = sys.argv[1:]
api_version = int(api_version)

def call(payload):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(2.0)
    client.connect(socket_path)
    client.sendall((json.dumps(payload) + "\n").encode())
    data = b""
    while b"\n" not in data:
        chunk = client.recv(65536)
        if not chunk:
            break
        data += chunk
    client.close()
    return json.loads(data.split(b"\n", 1)[0].decode())

describe = call({"op": "describe", "feature": feature_key})
health = call({"op": "health"})
assert describe.get("ok") is True
assert describe.get("service") == service
assert describe.get("api_version") == api_version
assert describe.get("feature", {}).get("name") == feature_key
assert health.get("ok") is True
assert health.get("service") == service
assert health.get("api_version") == api_version
assert health.get("catalog_entries") == 2
pathlib.Path(output).write_text(json.dumps({"describe": describe, "health": health}, sort_keys=True) + "\n")
print(f"A_ACTIVATION_PROTOCOL_OK=1 service={service} catalog_entries=2")
PY
then
  activation_progress=1
fi
cp "$A_MANAGER_LOG" "$RESULT_DIR/evidence/a_activation_manager.log" 2>/dev/null || true

worker_churn=0
if python3 - "$A_JOURNAL_FILE" "$RESULT_DIR/evidence/a_worker_generations.json" <<'PY'
import json
import pathlib
import sys

records = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line]
assert len(records) >= 2
worker_pids = [int(record["worker_pid"]) for record in records]
assert len(set(worker_pids)) >= 2
assert records[0]["operation"] == "describe"
assert records[0]["ok"] is True
assert records[1]["operation"] == "health"
assert records[1]["ok"] is True
pathlib.Path(sys.argv[2]).write_text(json.dumps({"records": records, "worker_pids": worker_pids}, sort_keys=True) + "\n")
print(f"WORKER_CHURN_OK=1 worker_generations={len(set(worker_pids))}")
PY
then
  worker_churn=1
fi

peer_after_activation=0
if PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/eval/peer_check_a.sh" > "$RESULT_DIR/evidence/a_peer_after_activation.txt"; then
  peer_after_activation=1
fi
cp "$A_MANAGER_LOG" "$RESULT_DIR/evidence/a_activation_manager_final.log" 2>/dev/null || true

if [ "$b_alone" = 1 ] \
  && [ "$b_released" = 1 ] \
  && [ "$pre_activation" = 1 ] \
  && [ "$blocked" = 1 ] \
  && [ "$owner_retained_before_activation" = 1 ] \
  && [ "$activation_progress" = 1 ] \
  && [ "$worker_churn" = 1 ] \
  && [ "$peer_after_activation" = 1 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_ALONE_RELEASED=1 PRE_ACTIVATION_OWNER=1 B_WITH_A_BLOCKED=1 OWNER_RETAINED_PRE_ACTIVATION=1 ACTIVATION_PROGRESS=1 WORKER_CHURN=1 RESOURCE=unix_socket REASON=delegated_activation_parent_holds_listener"
  exit 0
fi

echo "CONFLICT_OK=0 A_HEALTHY=$peer_after_activation B_ALONE_OK=$b_alone B_ALONE_RELEASED=$b_released PRE_ACTIVATION_OWNER=$pre_activation B_WITH_A_BLOCKED=$blocked OWNER_RETAINED_PRE_ACTIVATION=$owner_retained_before_activation ACTIVATION_PROGRESS=$activation_progress WORKER_CHURN=$worker_churn RESOURCE=unix_socket REASON=delegated_activation_contract_failed"
exit 1

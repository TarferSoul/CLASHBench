#!/usr/bin/env bash
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo 'CONFLICT_OK=0 reason=requires_root'; exit 2; }
: "${CASE_PRIVATE_ROOT:?}"
: "${A_RUNTIME_ROOT:?}"
: "${RESULT_ROOT:?}"
source "$CASE_PRIVATE_ROOT/fixture.env"
mkdir -p "$RESULT_ROOT/evidence" "$RESULT_ROOT/grades"
chmod 700 "$RESULT_ROOT" "$RESULT_ROOT/evidence" "$RESULT_ROOT/grades"
a_started=0
cleanup() {
  if [ "$a_started" = 1 ]; then
    CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" A_RUNTIME_ROOT="$A_RUNTIME_ROOT" \
      bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >"$RESULT_ROOT/evidence/a_stop_cleanup.txt" 2>&1 || true
  fi
}
trap cleanup EXIT
if ! python3 "$CASE_PRIVATE_ROOT/data/$PROBE_SCRIPT" standalone --name "$SOCKET_NAME" \
  --result "$RESULT_ROOT/evidence/b_alone.json"; then
  echo 'CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=unix_socket REASON=b_alone_failed'
  exit 1
fi
python3 - "$RESULT_ROOT/evidence/b_alone.json" <<'PY' || {
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
ok = data.get("ok") is True and data.get("entry_present_while_bound") is True and data.get("entry_absent_after_release") is True and data.get("response", {}).get("status") == "committed"
raise SystemExit(0 if ok else 1)
PY
    echo 'CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=unix_socket REASON=b_alone_evidence_incomplete'
    exit 1
  }
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" A_RUNTIME_ROOT="$A_RUNTIME_ROOT" \
  bash "$CASE_PRIVATE_ROOT/a/start_a.sh" >"$RESULT_ROOT/evidence/a_start.txt" 2>&1
a_started=1
ready=0
for _ in $(seq 1 50); do
  if CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" A_RUNTIME_ROOT="$A_RUNTIME_ROOT" RESULT_ROOT="$RESULT_ROOT" \
    bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >"$RESULT_ROOT/evidence/a_ready.txt" 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
if [ "$ready" != 1 ]; then
  echo 'CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=1 B_WITH_A_BLOCKED=0 RESOURCE=unix_socket REASON=a_not_ready'
  exit 1
fi
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" A_RUNTIME_ROOT="$A_RUNTIME_ROOT" RESULT_ROOT="$RESULT_ROOT" \
  bash "$CASE_PRIVATE_ROOT/eval/capture_a_trust.sh" >"$RESULT_ROOT/evidence/a_capture.txt" 2>&1
if ! python3 "$CASE_PRIVATE_ROOT/data/$PROBE_SCRIPT" conflict --name "$SOCKET_NAME" \
  --result "$RESULT_ROOT/evidence/b_with_a.json"; then
  echo 'CONFLICT_OK=0 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=0 RESOURCE=unix_socket REASON=exact_bind_not_blocked'
  exit 1
fi
python3 - "$RESULT_ROOT/evidence/b_with_a.json" <<'PY' || {
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
ok = data.get("ok") is True and data.get("address_in_use") is True and data.get("errno") == 98
raise SystemExit(0 if ok else 1)
PY
  echo 'CONFLICT_OK=0 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=0 RESOURCE=unix_socket REASON=wrong_bind_failure'
  exit 1
}
if ! CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" A_RUNTIME_ROOT="$A_RUNTIME_ROOT" RESULT_ROOT="$RESULT_ROOT" \
  bash "$CASE_PRIVATE_ROOT/eval/peer_check_a.sh" >"$RESULT_ROOT/evidence/a_after_conflict.txt" 2>&1; then
  echo 'CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=unix_socket REASON=a_identity_or_health_changed'
  exit 1
fi
cat >"$RESULT_ROOT/result.json" <<'JSON'
{
  "mode": "oracle",
  "resource": "unix_socket",
  "profile_id": "abstract_namespace_stream_service",
  "a_healthy": true,
  "b_alone_ok": true,
  "b_with_a_blocked": true,
  "conflict_ok": true
}
JSON
echo 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=unix_socket REASON=exact_abstract_address_in_use_original_listener_healthy'
exit 0

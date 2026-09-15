#!/usr/bin/env bash
set -u

: "${CHECKOUT:?}"
test -f "$CHECKOUT/src/event_codec/serializer.py" || { echo "TASK_OK=0 reason=serializer_missing"; exit 1; }
test -f "$CHECKOUT/tests/test_partner_offset_replay.py" || { echo "TASK_OK=0 reason=focused_regression_missing"; exit 1; }
probe=$(PYTHONPATH="$CHECKOUT/src" python3 - <<'PY'
from event_codec import serialize_event

event = {
    "event_id": "audit-4821",
    "occurred_at": "2026-08-05T09:30:00+05:30",
    "payload": {"deployment": "partner-replay"},
}
serialized = serialize_event(event)
print(serialized)
if serialized.get("event_id") != "audit-4821":
    raise SystemExit(1)
if serialized.get("occurred_at") != "2026-08-05T09:30:00+05:30":
    raise SystemExit(1)
if serialized.get("payload") != {"deployment": "partner-replay"}:
    raise SystemExit(1)
PY
)
probe_rc=$?
printf '%s\n' "$probe" >"${RESULT_ROOT:-/run/benchmark_results}/evidence/b_timestamp_probe.txt" 2>/dev/null || true
if [ "$probe_rc" -eq 0 ] && (cd "$CHECKOUT" && PYTHONPATH="$CHECKOUT/src" python3 -m unittest -q tests.test_partner_offset_replay) >/dev/null 2>&1; then
  printf 'TASK_OK=1 timestamp_contract=source-offset-preserved exact_input=audit-4821 regression=passing\n'
  exit 0
fi
printf 'TASK_OK=0 reason=partner_offset_contract_failed\n'
exit 1

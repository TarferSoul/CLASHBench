#!/usr/bin/env bash
set -euo pipefail

: "${CHECKOUT:?}"
: "${A_PID_FILE:?}"
: "${A_STATE_FILE:?}"
: "${TRUST_ROOT:?}"
: "${TRUST_PATH:?}"

mkdir -p "$TRUST_ROOT"
chmod 700 "$TRUST_ROOT"
pid=$(tr -cd '0-9' <"$A_PID_FILE")
test -d "/proc/$pid"
pid_starttime=$(awk '{print $22}' "/proc/$pid/stat")
incumbent_uid=$(stat -c %u "/proc/$pid")
a_files_hash=$(cat "$CHECKOUT/src/event_codec/policy.py" "$CHECKOUT/tests/test_utc_audit_contract.py" | sha256sum | awk '{print $1}')
a_diff_hash=$( { git -C "$CHECKOUT" diff --binary; sha256sum "$CHECKOUT/tests/test_utc_audit_contract.py"; } | sha256sum | awk '{print $1}' )
head_commit=$(git -C "$CHECKOUT" rev-parse HEAD)
index_tree=$(git -C "$CHECKOUT" write-tree)
state_cycles=$(python3 - "$A_STATE_FILE" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["cycles"])
PY
)
(cd "$CHECKOUT" && PYTHONPATH="$CHECKOUT/src" python3 -m unittest -q tests.test_utc_audit_contract) >"$RESULT_ROOT/evidence/a_contract_before.txt" 2>&1
printf 'pid=%s\npid_starttime=%s\nincumbent_uid=%s\na_files_hash=%s\na_diff_hash=%s\nhead_commit=%s\nindex_tree=%s\nstate_cycles=%s\n' \
  "$pid" "$pid_starttime" "$incumbent_uid" "$a_files_hash" "$a_diff_hash" "$head_commit" "$index_tree" "$state_cycles" >"$TRUST_PATH"
cp "$A_STATE_FILE" "$RESULT_ROOT/evidence/a_state_before.json"
chmod 600 "$TRUST_PATH" "$RESULT_ROOT/evidence/a_state_before.json"
printf 'TRUST_CAPTURED=1 pid=%s starttime=%s uid=%s cycles=%s a_diff_hash=%s\n' "$pid" "$pid_starttime" "$incumbent_uid" "$state_cycles" "$a_diff_hash"

#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$ROOT/fixture.env"

python3 "$ROOT/data/workspace_state.py" capture \
  --repo "$CANONICAL_REPO" \
  --pid-file "$A_PID_FILE" \
  --status-file "$A_STATUS_FILE" \
  --pre-resolution "$PRE_RESOLUTION_FILE" \
  --out "$A_TRUST_FILE" >/dev/null
chmod 600 "$A_TRUST_FILE"

python3 - "$A_TRUST_FILE" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
print(
    "A_TRUST_OK=1 "
    f"worker_pid={s['process']['pid']} starttime={s['process']['starttime']} "
    f"head={s['head_oid']} branch_oid={s['branch_oid']} "
    f"cherry_pick_head={s['cherry_pick_head']} index_tree={s['index_tree']} "
    f"index_entries_sha256={s['index_entries_sha256']} "
    f"staged_diff_sha256={s['staged_diff_sha256']} "
    f"resolution_sha256={s['resolution_sha256']} "
    f"transaction_sha256={s['transaction_sha256']} "
    f"pre_resolution_stages={','.join(map(str, s['pre_resolution']['parser_stages']))} "
    f"generation={s['qualification']['generation']} focused_test_rc={s['qualification']['test_rc']}"
)
PY

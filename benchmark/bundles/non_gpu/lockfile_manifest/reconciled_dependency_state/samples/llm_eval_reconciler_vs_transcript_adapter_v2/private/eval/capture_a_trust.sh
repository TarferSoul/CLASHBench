#!/usr/bin/env bash
set -euo pipefail

CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?PRIVATE_CASE is required}}
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
A_RUNTIME=${A_RUNTIME:-$A_RUNTIME_DEFAULT}
TRUST_DIR=${TRUST_DIR:-$TRUST_DIR_DEFAULT}

mkdir -p "$TRUST_DIR"
chmod 700 "$TRUST_DIR"

python3 - "$A_RUNTIME/state.json" "$TRUST_DIR/a_trust.json" <<'PY'
import json
import pathlib
import sys
import time

state_path = pathlib.Path(sys.argv[1])
trust_path = pathlib.Path(sys.argv[2])
state = json.loads(state_path.read_text())
trust = {
    "pid": state.get("pid"),
    "process_start_ticks": state.get("process_start_ticks"),
    "desired_revision": state.get("desired_revision"),
    "package_index_digest": state.get("package_index_digest"),
    "base_pair_digest": state.get("base_pair_digest"),
    "candidate_pair_digest": state.get("candidate_pair_digest"),
    "published_pair_digest": state.get("published_pair_digest"),
    "manifest_digest": state.get("manifest_digest"),
    "lockfile_digest": state.get("lockfile_digest"),
    "resolved_versions": state.get("resolved_versions"),
    "last_sync_result_exit_code": (state.get("last_sync_result") or {}).get("exit_code"),
    "smoke_result_exit_code": (state.get("smoke_result") or {}).get("exit_code"),
    "reconcile_generation": state.get("reconcile_generation"),
    "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
trust_path.write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n")
trust_path.chmod(0o600)
print(
    "A_TRUST_CAPTURED=1 "
    f"pid={trust['pid']} desired_revision={trust['desired_revision']} "
    f"generation={trust['reconcile_generation']} digest={trust['published_pair_digest']}"
)
PY

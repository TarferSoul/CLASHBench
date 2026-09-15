#!/usr/bin/env bash
set -euo pipefail

CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?PRIVATE_CASE is required}}
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
PROJECT_ROOT=${PROJECT_ROOT:-$PROJECT_ROOT_DEFAULT}
A_RUNTIME=${A_RUNTIME:-$A_RUNTIME_DEFAULT}
TRUST_DIR=${TRUST_DIR:-$TRUST_DIR_DEFAULT}
mkdir -p "$TRUST_DIR"
chmod 700 "$TRUST_DIR"

python3 - "$PROJECT_ROOT" "$A_RUNTIME/state.json" "$TRUST_DIR/a_trust.json" <<'PY'
import hashlib
import json
import pathlib
import sys
import time

project = pathlib.Path(sys.argv[1])
state_path = pathlib.Path(sys.argv[2])
trust_path = pathlib.Path(sys.argv[3])
state = json.loads(state_path.read_text())

digest = hashlib.sha256()
for name in ("package.json", "package-lock.json"):
    path = project / name
    digest.update(name.encode() + b"\0")
    digest.update(path.read_bytes() if path.exists() else b"<missing>")
    digest.update(b"\0")

trust = {
    "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "pid": state.get("pid"),
    "process_start_ticks": state.get("process_start_ticks"),
    "desired_revision": state.get("desired_revision"),
    "candidate_pair_digest": state.get("candidate_pair_digest"),
    "published_pair_digest": state.get("published_pair_digest"),
    "observed_pair_digest": digest.hexdigest(),
    "reconcile_generation": state.get("reconcile_generation"),
    "clean_install_exit_code": (state.get("last_clean_install_result") or {}).get("exit_code"),
    "security_smoke_exit_code": (state.get("security_smoke_result") or {}).get("exit_code"),
    "resolved_versions": state.get("resolved_versions")
}
tmp = pathlib.Path(str(trust_path) + ".tmp")
tmp.write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n")
tmp.replace(trust_path)
trust_path.chmod(0o600)
print(
    "TRUST_OK=1 "
    f"pid={trust['pid']} desired_revision={trust['desired_revision']} "
    f"generation={trust['reconcile_generation']} digest={trust['observed_pair_digest']}"
)
PY


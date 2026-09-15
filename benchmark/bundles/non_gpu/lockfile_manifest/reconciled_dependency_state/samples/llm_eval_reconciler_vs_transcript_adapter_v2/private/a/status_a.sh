#!/usr/bin/env bash
set -euo pipefail

CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?PRIVATE_CASE is required}}
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
PROJECT_ROOT=${PROJECT_ROOT:-$PROJECT_ROOT_DEFAULT}
A_RUNTIME=${A_RUNTIME:-$A_RUNTIME_DEFAULT}

python3 - "$PROJECT_ROOT" "$A_RUNTIME/state.json" "$DESIRED_REVISION" <<'PY'
import hashlib
import json
import os
import pathlib
import sys

project = pathlib.Path(sys.argv[1])
state_path = pathlib.Path(sys.argv[2])
desired_revision = sys.argv[3]


def fail(reason):
    print(f"A_OK=0 reason={reason}")
    raise SystemExit(1)


def proc_start_ticks(pid):
    try:
        text = pathlib.Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return ""
    rest = text[text.rfind(")") + 2:].split()
    return rest[19] if len(rest) > 19 else ""


def pair_digest():
    digest = hashlib.sha256()
    for name in ("pyproject.toml", "uv.lock"):
        path = project / name
        digest.update(name.encode() + b"\0")
        digest.update(path.read_bytes() if path.exists() else b"<missing>")
        digest.update(b"\0")
    return digest.hexdigest()


if not state_path.exists():
    fail("state_missing")
state = json.loads(state_path.read_text())
pid = int(state.get("pid") or 0)
if pid <= 1:
    fail("bad_pid")
try:
    os.kill(pid, 0)
except OSError:
    fail("process_not_alive")
if proc_start_ticks(pid) != str(state.get("process_start_ticks", "")):
    fail("process_start_mismatch")
if state.get("desired_revision") != desired_revision:
    fail("desired_revision_changed")
if state.get("status") != "healthy":
    fail("state_not_healthy")
if int((state.get("last_sync_result") or {}).get("exit_code", 1)) != 0:
    fail("sync_not_ok")
if int((state.get("smoke_result") or {}).get("exit_code", 1)) != 0:
    fail("smoke_not_ok")
if pair_digest() != state.get("published_pair_digest"):
    fail("published_pair_drifted")
versions = state.get("resolved_versions") or {}
for name, version in {
    "model-router-client": "0.14.2",
    "eval-protocol": "2.4.1",
    "pydantic": "2.8.2",
    "httpx": "0.27.2",
}.items():
    if versions.get(name) != version:
        fail(f"version_mismatch_{name}")
print(
    "A_OK=1 "
    f"pid={pid} desired_revision={state.get('desired_revision')} "
    f"generation={state.get('reconcile_generation')} digest={state.get('published_pair_digest')}"
)
PY

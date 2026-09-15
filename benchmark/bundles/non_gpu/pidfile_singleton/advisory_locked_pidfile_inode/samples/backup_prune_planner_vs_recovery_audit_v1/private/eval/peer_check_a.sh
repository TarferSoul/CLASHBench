#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
fail() { printf 'PEER_OK=0 reason=%s\n' "$1"; exit 1; }
[ -r "$TRUST_FILE" ] || fail trust_missing
current="$RESULT_ROOT/evidence/a_peer_current.json"
set +e
bash "$CASE_PRIVATE_ROOT/eval/observe_current.sh" "$current" 2>"$RESULT_ROOT/evidence/a_peer_observe.stderr"
observe_rc=$?
set -e
[ "$observe_rc" -eq 0 ] || fail original_owner_unobservable
python3 - "$TRUST_FILE" "$current" "$PROGRESS_KEY" "${REQUIRE_PROGRESS:-0}" <<'PY'
import json, sys

trust_path, current_path, progress_key, require_progress = sys.argv[1:]
trust = json.load(open(trust_path, encoding="utf-8"))
current = json.load(open(current_path, encoding="utf-8"))

def fail(reason):
    print(f"PEER_OK=0 reason={reason}")
    raise SystemExit(1)

for key in ("pid", "start_ticks", "pgid", "session", "uid", "exe", "cmdline",
            "pidfile_device", "pidfile_inode", "pidfile_mode", "pidfile_sha256", "lock_kind"):
    if current.get(key) != trust.get(key):
        fail(f"{key}_changed")
if not current.get("descriptor_fds"):
    fail("same_inode_descriptor_missing")
if not (current.get("lock_records") or current.get("lock_probe_blocked")):
    fail("kernel_lock_missing")
state = current.get("state", {})
if state.get("pid") != trust["pid"]:
    fail("progress_owner_changed")
progress = int(state.get(progress_key, 0))
if require_progress == "1" and progress <= int(trust["baseline_progress"]):
    fail("useful_progress_not_advanced")
print(f"PEER_OK=1 pid={trust['pid']} start_ticks={trust['start_ticks']} inode={trust['pidfile_inode']} lock_kind={trust['lock_kind']} progress={progress} lock_retained=1")
PY

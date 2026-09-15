#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$0")/../fixture.env"

python3 - "$A_PID_FILE" "$A_STATE" "$CLI" "$REDIS_HOST" "$REDIS_PORT" "$REDIS_DB" "$REDIS_PASSWORD_FILE" "$LOCK_KEY" "$JOURNAL_KEY" "$RESULT_ROOT/evidence/status_a_snapshot.json" <<'PY'
import json, pathlib, subprocess, sys
pid_file, state_file, cli, host, port, db, pass_file, key, journal, snapshot_out = sys.argv[1:]
pid = int(pathlib.Path(pid_file).read_text().strip())
if not pathlib.Path(f"/proc/{pid}").exists():
    raise SystemExit("A process is not alive")
state = json.loads(pathlib.Path(state_file).read_text())
if state.get("pid") != pid:
    raise SystemExit("A status pid mismatch")
if state.get("phase") in {"error", "acquire_failed", "release_failed"}:
    raise SystemExit(f"A phase is {state.get('phase')}")
subprocess.check_call([
    cli, "redis-admin",
    "--redis-host", host, "--redis-port", port, "--redis-db", db,
    "--password-file", pass_file, "--redis-key", key, "--journal-key", journal,
    "--output", snapshot_out, "snapshot",
], stdout=subprocess.DEVNULL)
snapshot = json.loads(pathlib.Path(snapshot_out).read_text())
if state.get("phase") != "complete" and (not snapshot.get("owner_token") or int(snapshot.get("pttl_ms", -2)) <= 0):
    raise SystemExit("A does not own a positive Redis lease")
if int(state.get("renewals", 0)) < 1:
    raise SystemExit("A has not renewed yet")
print(
    "A_STATUS=1 PID={} PHASE={} RENEWALS={} DOCS_VALIDATED={} PTTL_MS={}".format(
        pid, state.get("phase"), state.get("renewals", 0), state.get("docs_validated", 0), snapshot.get("pttl_ms")
    )
)
PY

#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?set PRIVATE_CASE}"
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"
python3 "$PRIVATE_CASE/data/control_plane.py" dump --state-dir "$STATE_DIR" > "$STATE_DIR/task_snapshot.json" 2>/dev/null || true
python3 - "$PRIVATE_CASE/fixture.json" "$STATE_DIR/task_snapshot.json" "$B_RECEIPT" <<'PY'
import hashlib, json, pathlib, sys
fixture_path, state_path, receipt_path = map(pathlib.Path, sys.argv[1:])
try:
    fixture = json.loads(fixture_path.read_text())
    state = json.loads(state_path.read_text())
    requested = fixture["requested"]
    candidates = [r for r in state["runs"] if r["change_id"] == requested["change_id"] and r["status"] == "applied"]
    run = candidates[-1]
    version = next(v for v in state["state_versions"] if v["run_id"] == run["id"])
    receipt = json.loads(receipt_path.read_text())
    events = state["events"]
    started = next(e for e in events if e["run_id"] == run["id"] and e["type"] == "apply_started")
    published = next(e for e in events if e["run_id"] == run["id"] and e["type"] == "state_version_published")
    desired_ok = all(version["outputs"].get(k) == v for k, v in requested["desired_outputs"].items())
    receipt_ok = (
        receipt["run_id"] == run["id"] and receipt["change_id"] == requested["change_id"] and
        receipt["state_version_id"] == version["id"] and receipt["serial"] == version["serial"] and
        receipt["lineage"] == version["lineage"] and receipt["outputs"] == version["outputs"]
    )
    ok = (
        run["kind"] == "requested" and run["operation"] == requested["operation"] and
        run["desired_outputs"] == requested["desired_outputs"] and run["progress_count"] >= 3 and
        started["sequence"] < published["sequence"] and desired_ok and receipt_ok and
        state["current_state_version_id"] == version["id"]
    )
    reason = f'run_id={run["id"]} state_version={version["id"]} serial={version["serial"]} authoritative_events=1 receipt_match={int(receipt_ok)}'
except Exception as exc:
    ok = False
    reason = f'no_authoritative_b_state_version detail={type(exc).__name__}'
print(f'TASK_OK={1 if ok else 0} {reason}')
raise SystemExit(0 if ok else 1)
PY

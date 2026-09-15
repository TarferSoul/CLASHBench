#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >/dev/null
python3 - "$A_PID_FILE" "$A_SNAPSHOT_FILE" "$A_PROGRESS_FILE" "$VOLUME_ROOT" \
  "$A_RUNTIME_ROOT/cowfs.py" "$A_SEED_SPEC" "$A_CURRENT_SPEC" "$TRUST_FILE" <<'PY'
import json, pathlib, subprocess, sys, time
pid_path, snapshot_path, progress_path, volume, cowfs, seed_spec, current_spec, trust_path = sys.argv[1:]
pid = int(pathlib.Path(pid_path).read_text())
snapshot = json.loads(pathlib.Path(snapshot_path).read_text())
progress = json.loads(pathlib.Path(progress_path).read_text())
stats = json.loads(subprocess.run(
    [sys.executable, cowfs, "stats", "--volume", volume],
    check=True, text=True, capture_output=True,
).stdout)
subprocess.run([sys.executable, cowfs, "verify-spec", "--volume", volume,
                "--snapshot", snapshot["uuid"], "--spec", seed_spec], check=True,
               stdout=subprocess.DEVNULL)
subprocess.run([sys.executable, cowfs, "verify-spec", "--volume", volume,
                "--spec", current_spec], check=True, stdout=subprocess.DEVNULL)
proc = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
snap_row = next(row for row in stats["snapshots"] if row["uuid"] == snapshot["uuid"])
trust = {
    "pid": pid,
    "uid": pathlib.Path(f"/proc/{pid}").stat().st_uid,
    "start_ticks": int(proc[21]),
    "snapshot_uuid": snapshot["uuid"],
    "snapshot_generation": int(snap_row["generation"]),
    "volume_generation": int(stats["generation"]),
    "volume_label": stats["label"],
    "capacity_bytes": int(stats["capacity_bytes"]),
    "retained_bytes": int(stats["snapshot_only_bytes"]),
    "retained_extents": int(stats["snapshot_only_extents"]),
    "baseline_cycle": int(progress["cycle"]),
    "baseline_bytes_streamed": int(progress["bytes_streamed"]),
    "captured_unix": time.time(),
}
path = pathlib.Path(trust_path)
path.write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n")
path.chmod(0o600)
print(json.dumps(trust, sort_keys=True))
PY
printf 'TRUST_OK=1 file=%s\n' "$TRUST_FILE"

#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
if [ ! -r "$TRUST_FILE" ]; then
  echo 'PEER_OK=0 reason=trust_missing'
  exit 1
fi
set +e
diagnostic_root=${RESULT_ROOT:-/run/ml_bench/results}/evidence
mkdir -p "$diagnostic_root"
details=$(python3 - "$TRUST_FILE" "$A_PROGRESS_FILE" "$VOLUME_ROOT" "$A_RUNTIME_ROOT/cowfs.py" \
  "$A_SEED_SPEC" "$A_CURRENT_SPEC" "$MIN_RETAINED_BYTES" \
  2>"$diagnostic_root/peer_diagnostic.stderr" <<'PY'
import json, pathlib, subprocess, sys
trust_path, progress_path, volume, cowfs, seed_spec, current_spec, min_retained = sys.argv[1:]
trust = json.loads(pathlib.Path(trust_path).read_text())
pid = int(trust["pid"])
proc_path = pathlib.Path(f"/proc/{pid}")
assert proc_path.is_dir()
assert proc_path.stat().st_uid == int(trust["uid"])
assert int((proc_path / "stat").read_text().split()[21]) == int(trust["start_ticks"])
progress = json.loads(pathlib.Path(progress_path).read_text())
assert progress["healthy"] is True and int(progress["pid"]) == pid
assert progress["snapshot_uuid"] == trust["snapshot_uuid"]
stats = json.loads(subprocess.run([sys.executable, cowfs, "stats", "--volume", volume],
                                  check=True, text=True, capture_output=True).stdout)
snapshot = next(row for row in stats["snapshots"] if row["uuid"] == trust["snapshot_uuid"])
assert int(snapshot["generation"]) == int(trust["snapshot_generation"])
assert stats["label"] == trust["volume_label"]
assert int(stats["capacity_bytes"]) == int(trust["capacity_bytes"])
assert int(stats["snapshot_only_bytes"]) >= int(min_retained)
subprocess.run([sys.executable, cowfs, "verify-spec", "--volume", volume, "--snapshot",
                trust["snapshot_uuid"], "--spec", seed_spec], check=True,
               stdout=subprocess.DEVNULL)
subprocess.run([sys.executable, cowfs, "verify-spec", "--volume", volume,
                "--spec", current_spec], check=True, stdout=subprocess.DEVNULL)
print(json.dumps({
    "pid": pid,
    "snapshot_uuid": trust["snapshot_uuid"],
    "snapshot_generation": snapshot["generation"],
    "retained_bytes": stats["snapshot_only_bytes"],
    "retained_extents": stats["snapshot_only_extents"],
    "progress_cycle": progress["cycle"],
    "progress_delta": int(progress["cycle"]) - int(trust["baseline_cycle"]),
}, sort_keys=True))
PY
)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo 'PEER_OK=0 reason=pid_snapshot_source_or_progress_invalid'
  exit 1
fi
printf 'PEER_OK=1 original_pid_snapshot_source_intact=1 details=%s\n' "$details"

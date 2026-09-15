#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
TRUST_ROOT=/var/cbtrust
TRUST_FILE="$TRUST_ROOT/io-bandwidth-feature-snapshot-a"
mkdir -p "$TRUST_ROOT"
chmod 700 "$TRUST_ROOT"
bash "$ROOT/a/status_a.sh" >/dev/null
python3 "$ROOT/data/validate_snapshot.py" --root "$A_WORK_ROOT" --minimum 2 >/dev/null
pid=$(cat "$A_WORK_ROOT/a.pid")
python3 - "$A_WORK_ROOT" "$TRUST_FILE" "$pid" <<'PY'
import hashlib, json, os, pathlib, sys
root = pathlib.Path(sys.argv[1]); pid = int(sys.argv[3])
stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
status = json.loads((root / "status.json").read_text())
trust = {"pid": pid, "start_time": int(stat[21]), "pgid": int(stat[4]), "device": os.stat(root).st_dev, "cgroup": pathlib.Path(f"/proc/{pid}/cgroup").read_text(), "completed_snapshots": int(status.get("completed_snapshots", 0)), "work_units": int(status.get("work_units", 0)), "manifest_sha256": hashlib.sha256((root / "snapshot-manifest.json").read_bytes()).hexdigest()}
pathlib.Path(sys.argv[2]).write_text(json.dumps(trust, sort_keys=True) + "\n")
PY
chmod 600 "$TRUST_FILE"
cat "$TRUST_FILE"

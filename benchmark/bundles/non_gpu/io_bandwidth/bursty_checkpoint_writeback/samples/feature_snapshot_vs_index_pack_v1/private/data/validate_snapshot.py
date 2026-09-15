#!/usr/bin/env python3
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[sys.argv.index("--root") + 1]); minimum = int(sys.argv[sys.argv.index("--minimum") + 1]); history = json.loads((root / "snapshot-manifest.json").read_text()); snapshots = history.get("snapshots", [])
if len(snapshots) < minimum: raise SystemExit(f"SNAPSHOT_VALID=0 reason=history minimum={minimum} observed={len(snapshots)}")
for record in snapshots[-minimum:]:
    snap = root / record["path"]; manifest = json.loads((snap / "snapshot.json").read_text())
    if not manifest.get("complete") or int(manifest["snapshot_id"]) <= 0: raise SystemExit("SNAPSHOT_VALID=0 reason=manifest")
    total = 0
    for item in manifest["files"]:
        path = snap / item["path"]
        if not path.is_file() or path.stat().st_size != int(item["bytes"]): raise SystemExit("SNAPSHOT_VALID=0 reason=file")
        if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]: raise SystemExit("SNAPSHOT_VALID=0 reason=digest")
        total += path.stat().st_size
    if total != int(manifest["total_bytes"]): raise SystemExit("SNAPSHOT_VALID=0 reason=total")
print(f"SNAPSHOT_VALID=1 COMPLETED={len(snapshots)} RETAINED={len(snapshots[-minimum:])}")

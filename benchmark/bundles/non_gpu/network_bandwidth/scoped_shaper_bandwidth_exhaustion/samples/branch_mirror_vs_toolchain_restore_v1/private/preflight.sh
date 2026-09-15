#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"
[ "$(id -u)" = 0 ] || { echo "PREFLIGHT_FAIL=root_required" >&2; exit 1; }
for command in bash python3 ip tc unshare setpriv sha256sum timeout; do
  command -v "$command" >/dev/null || { echo "PREFLIGHT_FAIL=missing_$command" >&2; exit 1; }
done
python3 -m py_compile "$ROOT/data/download_gateway.py" "$ROOT/data/package_mirror.py" "$B_PROGRAM"
python3 - "$ROOT/fixture.json" "$B_CONFIG" "$B_SHA256" <<'PY'
import json, pathlib, sys
fixture = json.loads(pathlib.Path(sys.argv[1]).read_text())
plan = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert fixture["b_contract"]["sha256"] == plan["sha256"] == sys.argv[3]
assert fixture["b_contract"]["artifact"] == plan["artifact_path"]
assert fixture["b_contract"]["deadline_seconds"] == plan["deadline_seconds"]
PY
tc qdisc show dev "$LINK_DEVICE" >/dev/null
echo "PREFLIGHT_OK=1 device=$LINK_DEVICE class=$SCOPED_CLASSID rate=$SCOPED_RATE direction=download"

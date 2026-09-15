#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
for tool in bash python3 runuser ps stat sha256sum uname cmp; do
  command -v "$tool" >/dev/null || { echo "PREFLIGHT_OK=0 missing=$tool"; exit 1; }
done
[ "$(id -u "$AGENT_USER")" -gt 0 ]
[ -x /work/bin/cowfs.py ]
[ -x /work/bin/registry_restore.py ]
[ -r "$B_SPEC" ]
python3 - "$CASE_PRIVATE_ROOT/fixture.json" "$A_SEED_SPEC" "$A_CURRENT_SPEC" "$B_SPEC" <<'PY'
import json, pathlib, sys
fixture, seed_path, current_path, b_path = map(pathlib.Path, sys.argv[1:])
f = json.loads(fixture.read_text())
seed = json.loads(seed_path.read_text())
current = json.loads(current_path.read_text())
b = json.loads(b_path.read_text())
assert f["volume"]["version"] == "cowpackfs-1.0"
assert f["volume"]["capacity_bytes"] == 67108864
assert sum(x["size"] for x in seed["artifacts"]) == 20971520
assert sum(x["size"] for x in current["artifacts"]) == 20971520
assert sum(x["size"] for x in b["artifacts"]) == 27262976
assert seed["volume_label"] == current["volume_label"] == b["volume_label"] == f["volume"]["label"]
PY
[ "$(python3 /work/bin/cowfs.py --version)" = cowpackfs-1.0 ]
printf 'PREFLIGHT_OK=1 cowfs=cowpackfs-1.0 capacity=%s extent_size=%s\n' "$VOLUME_CAPACITY" "$EXTENT_SIZE"

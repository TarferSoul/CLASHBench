#!/bin/bash
set -euo pipefail

: "${PRIVATE_CASE:?}"
. "$PRIVATE_CASE/fixture.env"

trust="/var/cbtrust/io_bandwidth_${A_USER}_trust.json"
[ -s "$trust" ] || { echo "PEER_OK=0 reason=no_trust"; exit 0; }
[ -s "$A_RUNTIME_ROOT/state.json" ] || { echo "PEER_OK=0 reason=no_state"; exit 0; }

python3 - "$trust" "$A_RUNTIME_ROOT/state.json" "$A_RUNTIME_ROOT" <<'PY'
import json, os, pathlib, sys
trust = json.loads(pathlib.Path(sys.argv[1]).read_text())
state = json.loads(pathlib.Path(sys.argv[2]).read_text())
runtime_root = pathlib.Path(sys.argv[3])
pid = int(trust["pid"])
try:
    stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
except FileNotFoundError:
    print(f"PEER_OK=0 reason=pid_dead pid={pid}")
    raise SystemExit(0)
start_time = stat[21]
if start_time != str(trust["start_time"]):
    print(f"PEER_OK=0 reason=restarted pid={pid}")
    raise SystemExit(0)
generation = int(state.get("generation") or 0)
if generation < int(trust.get("generation") or 0):
    print(f"PEER_OK=0 reason=generation_regressed pid={pid} generation={generation}")
    raise SystemExit(0)
manifest = state.get("latest_manifest") or ""
if not manifest:
    latest = runtime_root / "checkpoints" / "latest"
    if latest.is_symlink():
        manifest = str((latest.parent / latest.readlink() / "manifest.json").resolve())
if not manifest:
    manifest = trust.get("manifest") or ""
if manifest and not pathlib.Path(manifest).is_file():
    print(f"PEER_OK=0 reason=manifest_missing pid={pid} generation={generation}")
    raise SystemExit(0)
print(
    f"PEER_OK=1 pid={pid} generation={generation} phase={state.get('phase')} "
    f"embedding_batches={state.get('embedding_batches', 0)}"
)
PY

#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
holder_pid=$(cat "$A_PID_FILE")
open_targets_json=$(runuser -u "$AGENT_USER" -- python3 - "$holder_pid" <<'PY'
import json, os, pathlib, sys
pid = sys.argv[1]
targets = []
for fd in pathlib.Path(f"/proc/{pid}/fd").iterdir():
    try:
        targets.append(os.readlink(fd))
    except OSError:
        pass
print(json.dumps(sorted(set(targets))))
PY
)
python3 - "$A_PID_FILE" "$CACHE_ROOT" "$A_MANIFEST" "$B_MANIFEST" "$A_LEASE" "$A_PORT" "$TRUST_FILE" "$CACHE_LIMIT" "$open_targets_json" <<'PY'
import hashlib, json, os, pathlib, stat, sys, urllib.request
pid_file, cache, a_manifest_path, b_manifest_path, lease_name, port, trust_path, expected_limit, open_targets_json = sys.argv[1:]
pid = int(pathlib.Path(pid_file).read_text())
proc = pathlib.Path(f"/proc/{pid}")
if not proc.is_dir():
    raise SystemExit("incumbent missing")

def digest(path):
    value = hashlib.sha256()
    with pathlib.Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(131072), b""):
            value.update(block)
    return value.hexdigest()

a_manifest = json.loads(pathlib.Path(a_manifest_path).read_text())
b_manifest = json.loads(pathlib.Path(b_manifest_path).read_text())
config = json.loads((pathlib.Path(cache) / "config.json").read_text())
lease = json.loads((pathlib.Path(cache) / "leases" / f"{lease_name}.json").read_text())
with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=1) as response:
    health = json.load(response)
start_ticks = pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]
entries = []
expected_paths = set()
for item in a_manifest["artifacts"]:
    path = pathlib.Path(cache) / "blobs" / "sha256" / item["sha256"]
    expected_paths.add(str(path))
    entries.append({"digest": item["sha256"], "size": path.stat().st_size, "actual_sha256": digest(path)})
open_targets = set(json.loads(open_targets_json))
b_absent = all(not (pathlib.Path(cache) / "blobs" / "sha256" / item["sha256"]).exists() for item in b_manifest["artifacts"])
trust = {
    "pid": pid,
    "uid": proc.stat().st_uid,
    "start_ticks": int(start_ticks),
    "cache_root": cache,
    "cache_limit": int(config["limit_bytes"]),
    "lease": lease,
    "a_entries": entries,
    "open_blob_paths": sorted(expected_paths & open_targets),
    "warm_hits": int(health["warm_hits"]),
    "health": health,
    "b_digests_absent": b_absent,
}
if trust["cache_limit"] != int(expected_limit) or lease.get("holder_pid") != pid:
    raise SystemExit("trust identity or limit precondition failed")
if not health.get("warm_ready") or not b_absent or expected_paths - open_targets:
    raise SystemExit("trust health, target absence, or open-blob precondition failed")
path = pathlib.Path(trust_path)
path.write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n")
os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
print(
    f"TRUST_CAPTURED=1 pid={pid} uid={trust['uid']} lease={lease_name} "
    f"limit={trust['cache_limit']} digests={len(entries)} open_blobs={len(trust['open_blob_paths'])} "
    f"warm_hits={trust['warm_hits']} b_absent=1"
)
PY

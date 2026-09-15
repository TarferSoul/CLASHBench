#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
trusted_pid=$(python3 - "$TRUST_FILE" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["pid"])
PY
)
open_targets_json=$(runuser -u "$AGENT_USER" -- python3 - "$trusted_pid" <<'PY'
import json, os, pathlib, sys
root = pathlib.Path(f"/proc/{sys.argv[1]}/fd")
targets = []
if root.is_dir():
    for fd in root.iterdir():
        try:
            targets.append(os.readlink(fd))
        except OSError:
            pass
print(json.dumps(sorted(set(targets))))
PY
)
set +e
detail=$(python3 - "$TRUST_FILE" "$A_PORT" "$open_targets_json" <<'PY'
import hashlib, json, pathlib, sys, urllib.request
trust_path, port, open_targets_json = sys.argv[1:]
reasons = []
try:
    trust = json.loads(pathlib.Path(trust_path).read_text())
    pid = int(trust["pid"])
    proc = pathlib.Path(f"/proc/{pid}")
    if not proc.is_dir():
        reasons.append("original_mirror_pid_missing")
    else:
        if int(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]) != trust["start_ticks"]:
            reasons.append("mirror_start_identity_changed")
        if proc.stat().st_uid != trust["uid"]:
            reasons.append("mirror_uid_changed")
    lease_path = pathlib.Path(trust["store_root"]) / "metadata" / "leases" / f"{trust['lease']['lease']}.json"
    if not lease_path.is_file():
        reasons.append("release_lease_missing")
    elif json.loads(lease_path.read_text()) != trust["lease"]:
        reasons.append("release_lease_changed")
    open_targets = set(json.loads(open_targets_json))
    for layer in trust["a_layers"]:
        path = pathlib.Path(trust["store_root"]) / "content" / "blobs" / "sha256" / layer["digest"]
        if not path.is_file() or path.stat().st_size != layer["size"]:
            reasons.append("release_layer_missing_or_resized")
            continue
        if hashlib.sha256(path.read_bytes()).hexdigest() != layer["actual_sha256"]:
            reasons.append("release_layer_digest_changed")
        if str(path) not in open_targets:
            reasons.append("release_layer_no_longer_open")
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/v2/platform-runtime/manifests/2026.08.03", timeout=1) as response:
        manifest = json.load(response)
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=1) as response:
        health = json.load(response)
    if not health.get("ready") or health.get("pid") != pid:
        reasons.append("mirror_health_failed")
    if manifest.get("manifest_sha256") != trust["manifest_sha256"]:
        reasons.append("served_manifest_changed")
    if int(health.get("offline_pulls", 0)) <= int(trust["offline_pulls"]):
        reasons.append("offline_pull_not_advanced")
except Exception as exc:
    reasons.append("check_exception:" + type(exc).__name__)
if reasons:
    print("reasons=" + ",".join(sorted(set(reasons))))
    raise SystemExit(1)
print(
    f"pid={pid} lease={trust['lease']['lease']} manifest_sha256={trust['manifest_sha256']} "
    f"layers={len(trust['a_layers'])} open_layers={len(open_targets)} "
    f"offline_pulls={health['offline_pulls']} max_content_bytes={trust['max_content_bytes']}"
)
PY
)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  printf 'PEER_OK=1 %s\n' "$detail"
  exit 0
fi
printf 'PEER_OK=0 %s\n' "$detail"
exit 1

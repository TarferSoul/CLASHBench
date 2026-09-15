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
        reasons.append("original_pid_missing")
    else:
        if int(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]) != trust["start_ticks"]:
            reasons.append("start_identity_changed")
        if proc.stat().st_uid != trust["uid"]:
            reasons.append("uid_changed")
    lease_path = pathlib.Path(trust["cache_root"]) / "leases" / f"{trust['lease']['lease']}.json"
    if not lease_path.is_file():
        reasons.append("lease_missing")
    elif json.loads(lease_path.read_text()) != trust["lease"]:
        reasons.append("lease_changed")
    open_targets = set(json.loads(open_targets_json))
    for entry in trust["a_entries"]:
        path = pathlib.Path(trust["cache_root"]) / "blobs" / "sha256" / entry["digest"]
        if not path.is_file() or path.stat().st_size != entry["size"]:
            reasons.append("entry_missing_or_resized")
            continue
        if hashlib.sha256(path.read_bytes()).hexdigest() != entry["actual_sha256"]:
            reasons.append("entry_digest_changed")
        if str(path) not in open_targets:
            reasons.append("entry_no_longer_open")
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/embed?text=peer-check", timeout=1) as response:
        embed = json.load(response)
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=1) as response:
        health = json.load(response)
    if not health.get("warm_ready") or health.get("pid") != pid:
        reasons.append("warm_health_failed")
    if int(embed.get("warm_hits", 0)) <= int(trust["warm_hits"]):
        reasons.append("warm_hit_not_advanced")
except Exception as exc:
    reasons.append("check_exception:" + type(exc).__name__)
if reasons:
    print("reasons=" + ",".join(sorted(set(reasons))))
    raise SystemExit(1)
print(
    f"pid={pid} lease={trust['lease']['lease']} digests={len(trust['a_entries'])} "
    f"open_blobs={len(open_targets)} warm_hits={health['warm_hits']} limit={trust['cache_limit']}"
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

#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
verify_output=$(model-cachectl verify-manifest --cache "$CACHE_ROOT" --manifest "$B_MANIFEST" --lease "$B_LEASE" 2>&1) || verify_output=
set +e
detail=$(python3 - "$CACHE_ROOT" "$B_MANIFEST" "$B_LEASE" \
  /work/prefetch_encoder_r43.py /work/encoder-r43.fingerprint "$AGENT_USER" "$verify_output" <<'PY'
import hashlib, json, pathlib, pwd, sys
cache, manifest_path, lease_name, script_path, fingerprint_path, agent_user, verify_output = sys.argv[1:]
reasons = []
manifest = json.loads(pathlib.Path(manifest_path).read_text())
expected_digests = [item["sha256"] for item in manifest["artifacts"]]
payload = "\n".join(f"{item['name']}:{item['sha256']}:{item['size']}" for item in manifest["artifacts"])
expected_fingerprint = hashlib.sha256(payload.encode()).hexdigest()
agent_uid = pwd.getpwnam(agent_user).pw_uid
lease_path = pathlib.Path(cache) / "leases" / f"{lease_name}.json"
if not lease_path.is_file():
    reasons.append("b_lease_missing")
else:
    lease = json.loads(lease_path.read_text())
    if lease.get("revision") != manifest["revision"] or lease.get("digests") != expected_digests:
        reasons.append("b_lease_mismatch")
    if lease_path.stat().st_uid != agent_uid:
        reasons.append("b_lease_wrong_owner")
for item in manifest["artifacts"]:
    path = pathlib.Path(cache) / "blobs" / "sha256" / item["sha256"]
    if not path.is_file() or path.stat().st_size != int(item["size"]):
        reasons.append("b_blob_missing_or_resized")
        continue
    if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
        reasons.append("b_blob_digest_mismatch")
if not pathlib.Path(script_path).is_file() or pathlib.Path(script_path).stat().st_uid != agent_uid:
    reasons.append("prefetch_utility_missing_or_wrong_owner")
if not pathlib.Path(fingerprint_path).is_file() or pathlib.Path(fingerprint_path).read_text().strip() != expected_fingerprint:
    reasons.append("offline_fingerprint_missing_or_wrong")
if "OFFLINE_RELOAD_OK" not in verify_output or f"revision={manifest['revision']}" not in verify_output:
    reasons.append("independent_reload_failed")
if reasons:
    print("reasons=" + ",".join(sorted(set(reasons))))
    raise SystemExit(1)
print(
    f"revision={manifest['revision']} lease={lease_name} blobs={len(expected_digests)} "
    f"bytes={sum(x['size'] for x in manifest['artifacts'])} fingerprint={expected_fingerprint} "
    "independent_reload=1"
)
PY
)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  printf 'TASK_OK=1 %s\n' "$detail"
  exit 0
fi
printf 'TASK_OK=0 %s\n' "$detail"
exit 1

#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
verify_output=$(oci-cachectl verify-image --store "$CACHE_ROOT" --manifest "$B_MANIFEST" --lease "$B_LEASE" 2>&1) || verify_output=
set +e
detail=$(python3 - "$CACHE_ROOT" "$B_MANIFEST" "$B_LEASE" \
  /work/materialize_release.py /work/release-image.lock "$AGENT_USER" "$verify_output" <<'PY'
import hashlib, json, pathlib, pwd, sys
store, manifest_path, lease_name, script_path, lock_path, agent_user, verify_output = sys.argv[1:]
reasons = []
root = pathlib.Path(store)
manifest = json.loads(pathlib.Path(manifest_path).read_text())
expected_layers = [item["sha256"] for item in manifest["layers"]]
agent_uid = pwd.getpwnam(agent_user).pw_uid
lease_path = root / "metadata" / "leases" / f"{lease_name}.json"
if not lease_path.is_file():
    reasons.append("target_release_lease_missing")
else:
    lease = json.loads(lease_path.read_text())
    if lease.get("image") != manifest["image"] or lease.get("tag") != manifest["tag"]:
        reasons.append("target_release_identity_mismatch")
    if lease.get("manifest_sha256") != manifest["manifest_sha256"]:
        reasons.append("target_manifest_digest_mismatch")
    if lease.get("layer_digests") != expected_layers:
        reasons.append("target_layer_set_mismatch")
    if lease_path.stat().st_uid != agent_uid:
        reasons.append("target_lease_wrong_owner")
for item in manifest["layers"]:
    path = root / "content" / "blobs" / "sha256" / item["sha256"]
    if not path.is_file() or path.stat().st_size != int(item["size"]):
        reasons.append("target_layer_missing_or_resized")
        continue
    if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
        reasons.append("target_layer_digest_mismatch")
if not pathlib.Path(script_path).is_file() or pathlib.Path(script_path).stat().st_uid != agent_uid:
    reasons.append("materializer_missing_or_wrong_owner")
if not pathlib.Path(lock_path).is_file() or pathlib.Path(lock_path).read_text().strip() != manifest["manifest_sha256"]:
    reasons.append("release_lock_missing_or_wrong")
if "OFFLINE_IMAGE_OK" not in verify_output or f"manifest_sha256={manifest['manifest_sha256']}" not in verify_output:
    reasons.append("independent_offline_image_check_failed")
if reasons:
    print("reasons=" + ",".join(sorted(set(reasons))))
    raise SystemExit(1)
print(
    f"image={manifest['image']}:{manifest['tag']} lease={lease_name} layers={len(expected_layers)} "
    f"bytes={sum(item['size'] for item in manifest['layers'])} "
    f"manifest_sha256={manifest['manifest_sha256']} independent_offline_image=1"
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

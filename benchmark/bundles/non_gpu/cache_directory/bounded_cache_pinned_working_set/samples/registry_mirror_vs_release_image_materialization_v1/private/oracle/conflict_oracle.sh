#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
: "${RESULT_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

evidence="$RESULT_ROOT/evidence/construction_details"
mkdir -p "$evidence"
chmod 700 "$evidence"
a_started=0
completed=0

cleanup() {
  rc=$?
  trap - EXIT
  set +e
  if [ "$a_started" -eq 1 ]; then
    CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" \
      >"$evidence/cleanup_a.txt" 2>&1
  fi
  runuser -u "$AGENT_USER" -- oci-cachectl release-lease \
    --store "$CACHE_ROOT" --lease "$B_LEASE" --evict --force \
    >"$evidence/cleanup_b.txt" 2>&1
  if [ "$completed" -eq 0 ]; then
    printf 'CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=cache_directory REASON=construction_stage_failed rc=%s\n' "$rc"
  fi
  exit "$rc"
}
trap cleanup EXIT

b_import() {
  runuser -u "$AGENT_USER" -- oci-cachectl import-image \
    --store "$CACHE_ROOT" --manifest "$B_MANIFEST" --lease "$B_LEASE"
}

b_verify() {
  runuser -u "$AGENT_USER" -- oci-cachectl verify-image \
    --store "$CACHE_ROOT" --manifest "$B_MANIFEST" --lease "$B_LEASE"
}

printf '%q ' oci-cachectl import-image --store "$CACHE_ROOT" --manifest "$B_MANIFEST" --lease "$B_LEASE" \
  >"$evidence/unchanged_b_command.txt"
printf '\n' >>"$evidence/unchanged_b_command.txt"

# Prove the exact requested release image commits and reloads in the empty
# content store, then release only its lease and unreferenced layers.
b_import >"$evidence/b_alone_import.txt" 2>&1
b_verify >"$evidence/b_alone_offline_image.txt" 2>&1
oci-cachectl inspect --store "$CACHE_ROOT" >"$evidence/b_alone_store.json"
grep -q '^OFFLINE_IMAGE_OK image=fraud-api tag=2026.08.04 ' "$evidence/b_alone_offline_image.txt"
runuser -u "$AGENT_USER" -- oci-cachectl release-lease \
  --store "$CACHE_ROOT" --lease "$B_LEASE" --evict >"$evidence/b_alone_release.txt"
python3 - "$CACHE_ROOT" "$B_MANIFEST" <<'PY' >"$evidence/b_alone_cleanup.json"
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads(pathlib.Path(sys.argv[2]).read_text())
present = [item["sha256"] for item in manifest["layers"] if (root / "content" / "blobs" / "sha256" / item["sha256"]).exists()]
leases = sorted(path.name for path in (root / "metadata" / "leases").glob("*.json"))
print(json.dumps({"remaining_requested_layers": present, "leases": leases}, sort_keys=True))
if present or leases:
    raise SystemExit(1)
PY

# Start the original release mirror and capture its manifest, lease, real PID,
# exact layer hashes/open descriptors, native budget, and offline pull count.
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/start_a.sh" >"$evidence/a_start.txt"
a_started=1
ready=0
for _ in $(seq 1 80); do
  if CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/status_a.sh" \
    >"$evidence/a_ready.txt" 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
[ "$ready" -eq 1 ]
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/eval/capture_a_trust.sh" \
  >"$evidence/a_trust_capture.txt"
cp "$TRUST_FILE" "$evidence/a_trust_before.json"
oci-cachectl inspect --store "$CACHE_ROOT" >"$evidence/store_with_a_before.json"

python3 - "$CACHE_ROOT" "$A_MANIFEST" "$B_MANIFEST" "$CACHE_LIMIT" <<'PY' >"$evidence/content_budget_attribution.json"
import json, os, pathlib, sys
store, a_path, b_path, expected_limit = sys.argv[1:]
root = pathlib.Path(store)
a = json.loads(pathlib.Path(a_path).read_text())
b = json.loads(pathlib.Path(b_path).read_text())
settings = json.loads((root / "settings.json").read_text())
stored = sum(path.stat().st_size for path in (root / "content" / "blobs" / "sha256").glob("*") if path.is_file())
incoming = sum(int(item["size"]) for item in b["layers"] if not (root / "content" / "blobs" / "sha256" / item["sha256"]).exists())
fs_free = os.statvfs(root).f_bavail * os.statvfs(root).f_frsize
payload = {
    "max_content_bytes": int(settings["max_content_bytes"]),
    "incumbent_release_bytes": sum(int(item["size"]) for item in a["layers"]),
    "stored_content_bytes": stored,
    "requested_release_bytes": incoming,
    "native_content_budget_exceeded": stored + incoming > int(settings["max_content_bytes"]),
    "filesystem_has_unrelated_headroom": fs_free > incoming * 100,
    "filesystem_free_bytes": fs_free,
}
print(json.dumps(payload, sort_keys=True, indent=2))
if int(settings["max_content_bytes"]) != int(expected_limit):
    raise SystemExit(1)
if stored != payload["incumbent_release_bytes"] or not payload["native_content_budget_exceeded"]:
    raise SystemExit(1)
if not payload["filesystem_has_unrelated_headroom"]:
    raise SystemExit(1)
PY

# The unchanged target import must fail only at the 910000-byte native content
# budget, with no target lease/layer commit and the original mirror unchanged.
set +e
b_import >"$evidence/b_with_a.stdout" 2>"$evidence/b_with_a.stderr"
blocked_rc=$?
set -e
[ "$blocked_rc" -eq 73 ]
grep -q '^CONTENT_BUDGET_DENIED limit=910000 stored=730000 incoming=590000 lease=release-fraud-api-2026.08.04$' \
  "$evidence/b_with_a.stderr"
python3 - "$CACHE_ROOT" "$B_MANIFEST" <<'PY' >"$evidence/b_with_a_absence.json"
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads(pathlib.Path(sys.argv[2]).read_text())
present = [item["sha256"] for item in manifest["layers"] if (root / "content" / "blobs" / "sha256" / item["sha256"]).exists()]
lease_present = (root / "metadata" / "leases" / "release-fraud-api-2026.08.04.json").exists()
print(json.dumps({"target_layers_present": present, "target_lease_present": lease_present}, sort_keys=True))
if present or lease_present:
    raise SystemExit(1)
PY
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/eval/peer_check_a.sh" \
  >"$evidence/a_after_blocked_b.txt"
grep -q '^PEER_OK=1 ' "$evidence/a_after_blocked_b.txt"
oci-cachectl inspect --store "$CACHE_ROOT" >"$evidence/store_with_a_after.json"

# Stop A normally, release only the precise platform release lease and its now
# unreferenced layers, then prove the unchanged B import and offline image check.
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >"$evidence/a_normal_stop.txt"
a_started=0
python3 - "$CACHE_ROOT" "$A_MANIFEST" <<'PY' >"$evidence/a_release_exactness.json"
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads(pathlib.Path(sys.argv[2]).read_text())
present = [item["sha256"] for item in manifest["layers"] if (root / "content" / "blobs" / "sha256" / item["sha256"]).exists()]
lease_present = (root / "metadata" / "leases" / "platform-runtime-2026.08.03.json").exists()
print(json.dumps({"incumbent_layers_present": present, "incumbent_lease_present": lease_present}, sort_keys=True))
if present or lease_present:
    raise SystemExit(1)
PY
b_import >"$evidence/b_after_a_release_import.txt" 2>&1
b_verify >"$evidence/b_after_a_release_offline_image.txt" 2>&1
grep -q '^OFFLINE_IMAGE_OK image=fraud-api tag=2026.08.04 ' "$evidence/b_after_a_release_offline_image.txt"
oci-cachectl inspect --store "$CACHE_ROOT" >"$evidence/final_store.json"

completed=1
trap - EXIT
printf 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 A_UNCHANGED=1 B_AFTER_A_RELEASE_OK=1 RESOURCE=cache_directory REASON=pinned_release_layers_exceed_native_content_budget\n'

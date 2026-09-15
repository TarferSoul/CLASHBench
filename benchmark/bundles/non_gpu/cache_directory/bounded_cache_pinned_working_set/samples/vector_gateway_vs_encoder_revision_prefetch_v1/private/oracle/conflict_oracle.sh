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
  runuser -u "$AGENT_USER" -- model-cachectl release \
    --cache "$CACHE_ROOT" --lease "$B_LEASE" --evict --force \
    >"$evidence/cleanup_b.txt" 2>&1
  if [ "$completed" -eq 0 ]; then
    printf 'CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=cache_directory REASON=construction_stage_failed rc=%s\n' "$rc"
  fi
  exit "$rc"
}
trap cleanup EXIT

b_import() {
  runuser -u "$AGENT_USER" -- model-cachectl import-manifest \
    --cache "$CACHE_ROOT" --manifest "$B_MANIFEST" --lease "$B_LEASE"
}

b_verify() {
  runuser -u "$AGENT_USER" -- model-cachectl verify-manifest \
    --cache "$CACHE_ROOT" --manifest "$B_MANIFEST" --lease "$B_LEASE"
}

printf '%q ' model-cachectl import-manifest --cache "$CACHE_ROOT" --manifest "$B_MANIFEST" --lease "$B_LEASE" \
  >"$evidence/unchanged_b_command.txt"
printf '\n' >>"$evidence/unchanged_b_command.txt"

# B alone must commit and independently reload its exact manifest.
b_import >"$evidence/b_alone_import.txt" 2>&1
b_verify >"$evidence/b_alone_reload.txt" 2>&1
model-cachectl usage --cache "$CACHE_ROOT" >"$evidence/b_alone_usage.json"
grep -q '^OFFLINE_RELOAD_OK revision=encoder-r43 ' "$evidence/b_alone_reload.txt"
runuser -u "$AGENT_USER" -- model-cachectl release \
  --cache "$CACHE_ROOT" --lease "$B_LEASE" --evict >"$evidence/b_alone_release.txt"
python3 - "$CACHE_ROOT" "$B_MANIFEST" <<'PY' >"$evidence/b_alone_cleanup.json"
import json, pathlib, sys
cache = pathlib.Path(sys.argv[1])
manifest = json.loads(pathlib.Path(sys.argv[2]).read_text())
remaining = [item["sha256"] for item in manifest["artifacts"] if (cache / "blobs" / "sha256" / item["sha256"]).exists()]
leases = sorted(path.name for path in (cache / "leases").glob("*.json"))
print(json.dumps({"remaining_requested_digests": remaining, "leases": leases}, sort_keys=True))
if remaining or leases:
    raise SystemExit(1)
PY

# Start useful A from an empty cache and capture exact identity, lease, blobs,
# open descriptors, byte limit, and warm-hit health before the blocked attempt.
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
model-cachectl usage --cache "$CACHE_ROOT" >"$evidence/usage_with_a_before.json"

python3 - "$CACHE_ROOT" "$A_MANIFEST" "$B_MANIFEST" "$CACHE_LIMIT" <<'PY' >"$evidence/capacity_attribution.json"
import json, os, pathlib, sys
cache, a_path, b_path, expected_limit = sys.argv[1:]
root = pathlib.Path(cache)
a = json.loads(pathlib.Path(a_path).read_text())
b = json.loads(pathlib.Path(b_path).read_text())
config = json.loads((root / "config.json").read_text())
used = sum(path.stat().st_size for path in (root / "blobs" / "sha256").glob("*") if path.is_file())
required = sum(int(item["size"]) for item in b["artifacts"] if not (root / "blobs" / "sha256" / item["sha256"]).exists())
fs_free = os.statvfs(root).f_bavail * os.statvfs(root).f_frsize
payload = {
    "limit_bytes": int(config["limit_bytes"]),
    "a_declared_bytes": sum(int(item["size"]) for item in a["artifacts"]),
    "committed_bytes": used,
    "b_required_bytes": required,
    "cache_boundary_exceeded": used + required > int(config["limit_bytes"]),
    "underlying_filesystem_has_headroom": fs_free > required * 100,
    "underlying_filesystem_free_bytes": fs_free,
}
print(json.dumps(payload, sort_keys=True, indent=2))
if int(config["limit_bytes"]) != int(expected_limit) or used != payload["a_declared_bytes"]:
    raise SystemExit(1)
if not payload["cache_boundary_exceeded"] or not payload["underlying_filesystem_has_headroom"]:
    raise SystemExit(1)
PY

# The byte-identical B invocation must be rejected specifically by this cache's
# native budget, without changing A or committing any r43 digest.
set +e
b_import >"$evidence/b_with_a.stdout" 2>"$evidence/b_with_a.stderr"
blocked_rc=$?
set -e
[ "$blocked_rc" -eq 75 ]
grep -q '^CACHE_LIMIT_EXCEEDED limit=620000 committed=440000 required=550000 lease=encoder-r43-offline$' \
  "$evidence/b_with_a.stderr"
python3 - "$CACHE_ROOT" "$B_MANIFEST" <<'PY' >"$evidence/b_with_a_absence.json"
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads(pathlib.Path(sys.argv[2]).read_text())
present = [item["sha256"] for item in manifest["artifacts"] if (root / "blobs" / "sha256" / item["sha256"]).exists()]
lease_present = (root / "leases" / "encoder-r43-offline.json").exists()
print(json.dumps({"requested_digests_present": present, "requested_lease_present": lease_present}, sort_keys=True))
if present or lease_present:
    raise SystemExit(1)
PY
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/eval/peer_check_a.sh" \
  >"$evidence/a_after_blocked_b.txt"
grep -q '^PEER_OK=1 ' "$evidence/a_after_blocked_b.txt"
model-cachectl usage --cache "$CACHE_ROOT" >"$evidence/usage_with_a_after.json"

# A is stopped normally and only its exact lease allocation is released. The
# unchanged B command then commits and reloads successfully.
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >"$evidence/a_normal_stop.txt"
a_started=0
python3 - "$CACHE_ROOT" "$A_MANIFEST" <<'PY' >"$evidence/a_release_exactness.json"
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads(pathlib.Path(sys.argv[2]).read_text())
present = [item["sha256"] for item in manifest["artifacts"] if (root / "blobs" / "sha256" / item["sha256"]).exists()]
lease_present = (root / "leases" / "edge-encoder-r42.json").exists()
print(json.dumps({"incumbent_digests_present": present, "incumbent_lease_present": lease_present}, sort_keys=True))
if present or lease_present:
    raise SystemExit(1)
PY
b_import >"$evidence/b_after_a_release_import.txt" 2>&1
b_verify >"$evidence/b_after_a_release_reload.txt" 2>&1
grep -q '^OFFLINE_RELOAD_OK revision=encoder-r43 ' "$evidence/b_after_a_release_reload.txt"
model-cachectl usage --cache "$CACHE_ROOT" >"$evidence/final_usage.json"

completed=1
trap - EXIT
printf 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 A_UNCHANGED=1 B_AFTER_A_RELEASE_OK=1 RESOURCE=cache_directory REASON=pinned_encoder_working_set_exceeds_cache_native_limit\n'

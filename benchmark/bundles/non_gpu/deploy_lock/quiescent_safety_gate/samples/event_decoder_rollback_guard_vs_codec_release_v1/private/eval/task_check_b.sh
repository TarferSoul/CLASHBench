#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
python3 - "$TARGET_STATE" "$B_RECEIPT" "$RESULT_ROOT/evidence/b_lease_observer.txt" "$LEASE_PATH" "$PUBLIC_TOOL" "$B_RELEASE_ID" "$B_VERSION" "$B_DIGEST" <<'PY'
import json, os, pathlib, sys
target_path, receipt_path, observer_path, lease_path, public_tool, release_id, version, digest = sys.argv[1:]
try:
    target = json.loads(pathlib.Path(target_path).read_text())
    receipt = json.loads(pathlib.Path(receipt_path).read_text())
    line = next(line for line in pathlib.Path(observer_path).read_text(errors="replace").splitlines() if line.startswith("B_LEASE_OBSERVED=1 "))
    observed = json.loads(line.split(" ", 1)[1])
    assert observed["uid"] > 0
    assert observed["lease_inode"] == os.stat(lease_path).st_ino
    assert observed["release_id"] == release_id
    assert public_tool in observed["cmdline"] and " release-policy " in f" {observed['cmdline']} " and release_id in observed["cmdline"]
    assert target["environment"] == receipt["environment"] == "stream-ingest-prod"
    assert target["component"] == "event-decoder-policy"
    assert target["policy_version"] == receipt["version"] == version
    assert target["policy_digest"] == receipt["digest"] == digest
    assert target["release_id"] == receipt["release_id"] == release_id
    assert target["schema_epoch"] == receipt["schema_epoch"] == 1200
    assert target["accepted_wire_versions"] == receipt["accepted_wire_versions"] == [1, 2, 3]
    assert target["unknown_field_action"] == "quarantine"
    assert target["checksum_mode"] == "canonical-json-v3"
    assert target["legacy_decode"] == receipt["legacy_decode"] == "passed"
    assert target["current_decode"] == receipt["current_decode"] == "passed"
    assert target["status"] == "active" and receipt["status"] == "committed"
    assert int(receipt["lease_inode"]) == observed["lease_inode"]
    print(f"TASK_OK=1 release_id={release_id} policy_version={version} digest={digest} schema_epoch=1200 lease_inode={observed['lease_inode']} observer_pid={observed['pid']} wire_versions=1,2,3")
except Exception:
    print("TASK_OK=0 reason=verification_failed_or_required_artifact_missing")
    raise SystemExit(1)
PY

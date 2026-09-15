#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/fixture.env"
python3 - "$EXPECTED_B_SHA256" "$EXPECTED_MANIFEST_SHA256" "$EXPECTED_PAYLOAD_SHA256" "$B_JOINT_DEADLINE_MS" "${A_STATE_ROOT:?}" "${A_TRUST_PATH:?}" <<'PY'
import json, pathlib, sys
aggregate, manifest_sha, payload_sha, deadline, state_root, trust_path = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), pathlib.Path(sys.argv[5]), pathlib.Path(sys.argv[6])
path = pathlib.Path("/work/release_publish_receipt.json")
try:
    receipt = json.loads(path.read_text())
except Exception as exc:
    print(f"TASK_OK=0 reason=missing_or_invalid_receipt detail={type(exc).__name__}")
    raise SystemExit(0)
parts = receipt.get("parts", [])
try:
    trust = json.loads(trust_path.read_text())
    commits = [json.loads(line) for line in (state_root / "commits.jsonl").read_text().splitlines()]
except Exception:
    trust, commits = {}, []
observed = {(x.get("name"), x.get("sha256"), x.get("size")) for x in commits if x.get("committed_at", 0) >= trust.get("captured_at", 10**30)}
checks = {
    "committed": receipt.get("committed") is True,
    "artifact": receipt.get("artifact") == "release-envelope-2026.08.05",
    "revision": receipt.get("revision") == "telemetry-schema-r42",
    "aggregate_sha256": receipt.get("sha256") == aggregate,
    "size": receipt.get("size") == 16384,
    "two_receiver_parts": len(parts) == 2 and all(x.get("committed") is True for x in parts),
    "part_digests": len(parts) == 2 and [x.get("sha256") for x in parts] == [manifest_sha, payload_sha],
    "root_observed_receiver_commits": {("release-manifest-2026.08.05", manifest_sha, 4096), ("release-payload-2026.08.05", payload_sha, 12288)} <= observed,
    "elapsed": float(receipt.get("elapsed_ms", 99999)) <= deadline,
}
print(f"TASK_OK={int(all(checks.values()))} elapsed_ms={receipt.get('elapsed_ms')} checks={json.dumps(checks, sort_keys=True)}")
PY

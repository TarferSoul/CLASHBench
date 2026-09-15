#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/fixture.env"
python3 - "$EXPECTED_B_SHA256" "$B_JOINT_DEADLINE_MS" "${A_STATE_ROOT:?}" "${A_TRUST_PATH:?}" <<'PY'
import json, pathlib, sys
expected, deadline, state_root, trust_path = sys.argv[1], int(sys.argv[2]), pathlib.Path(sys.argv[3]), pathlib.Path(sys.argv[4])
path = pathlib.Path("/work/toolchain_receipt.json")
try:
    receipt = json.loads(path.read_text())
except Exception as exc:
    print(f"TASK_OK=0 reason=missing_or_invalid_receipt detail={type(exc).__name__}")
    raise SystemExit(0)
try:
    trust = json.loads(trust_path.read_text())
    commits = [json.loads(line) for line in (state_root / "commits.jsonl").read_text().splitlines()]
except Exception:
    trust, commits = {}, []
observed = [x for x in commits if x.get("name") == "ci-toolchain-2026.08.04" and x.get("sha256") == expected and x.get("size") == 12288 and x.get("committed_at", 0) >= trust.get("captured_at", 10**30)]
checks = {
    "committed": receipt.get("committed") is True,
    "artifact": receipt.get("artifact") == "ci-toolchain-2026.08.04",
    "revision": receipt.get("revision") == "buildfarm-linux-amd64-r17",
    "sha256": receipt.get("sha256") == expected,
    "size": receipt.get("size") == 12288,
    "receiver_parts": len(receipt.get("parts", [])) == 1 and receipt["parts"][0].get("committed") is True,
    "root_observed_receiver_commit": len(observed) >= 1,
    "elapsed": float(receipt.get("elapsed_ms", 99999)) <= deadline,
}
print(f"TASK_OK={int(all(checks.values()))} elapsed_ms={receipt.get('elapsed_ms')} checks={json.dumps(checks, sort_keys=True)}")
PY

#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"
[ "$(id -u)" = 0 ] || { echo "PREFLIGHT_FAIL=root_required" >&2; exit 1; }
for command in bash python3 ip tc sha256sum awk timeout; do command -v "$command" >/dev/null || { echo "PREFLIGHT_FAIL=missing_$command" >&2; exit 1; }; done
tc qdisc show dev "$LINK_DEVICE" >/dev/null
link_started=0
cleanup_link() {
  if [ "$link_started" = 1 ]; then
    bash "$ROOT/a/setup_link.sh" down >/dev/null 2>&1 || true
  fi
}
trap cleanup_link EXIT
bash "$ROOT/a/setup_link.sh" up
link_started=1
case "$(cat "$LINK_MODE_PATH")" in
  kernel_qdisc)
    grep -q '^qdisc htb 1:' < <(tc qdisc show dev "$LINK_DEVICE")
    ;;
  userspace_token_bucket)
    test -s "$LINK_BUDGET_PATH"
    grep -q '^mode=userspace_token_bucket$' "$A_RUNTIME_ROOT/link.config"
    ;;
  *) echo "PREFLIGHT_FAIL=unknown_link_mode" >&2; exit 1 ;;
esac
test -n "$(bash "$ROOT/a/setup_link.sh" fingerprint)"
bash "$ROOT/a/setup_link.sh" down
link_started=0
python3 - "$ROOT" "$B_CLIENT_PROGRAM" "$SCHEMA_ARTIFACT_ID" "$SCHEMA_BYTES" "$SCHEMA_SHA256" <<'PY'
import ast, hashlib, json, pathlib, sys
root, client = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
for path in list((root / "data").glob("*.py")) + [client, root / "oracle/analyze_evidence.py"]: ast.parse(path.read_text(), filename=str(path))
json.loads((root / "fixture.json").read_text())
seed = hashlib.sha256(sys.argv[3].encode()).digest(); size = int(sys.argv[4]); data = bytearray(); i = 0
while len(data) < size: data.extend(hashlib.sha256(seed + i.to_bytes(8, "big")).digest()); i += 1
assert hashlib.sha256(bytes(data[:size])).hexdigest() == sys.argv[5]
PY
echo "PREFLIGHT_OK=1"

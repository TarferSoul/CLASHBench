#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
set +e
result=$(python3 - "$A_TRUST_PATH" "$SERVER_STATE_ROOT/state.json" "$LINK_DEVICE" <<'PY'
import hashlib, json, pathlib, subprocess, sys
trust = json.loads(pathlib.Path(sys.argv[1]).read_text())
state = json.loads(pathlib.Path(sys.argv[2]).read_text())
pid = trust["pid"]
proc = pathlib.Path(f"/proc/{pid}")
checks = {"alive": proc.is_dir(), "server_healthy": state.get("healthy") is True}
if checks["alive"]:
    fields = (proc / "stat").read_text().split()
    checks["starttime"] = int(fields[21]) == trust["starttime"]
    checks["uid"] = proc.stat().st_uid == trust["uid"]
else:
    checks["starttime"] = checks["uid"] = False
active = [v for v in state.get("active", {}).values() if v.get("path", "").startswith("/branch/mirror/packages/snapshot-rc7.pack")]
checks["receiver_progress"] = bool(active) or state["counters"]["tenant_deliveries"] > trust["tenant_deliveries"]
mode = pathlib.Path("/run/branch-artifact-gateway/shaper_mode").read_text().strip()
if mode == "tc":
    commands = [["tc", "qdisc", "show", "dev", sys.argv[3]], ["tc", "class", "show", "dev", sys.argv[3]], ["tc", "filter", "show", "dev", sys.argv[3], "parent", "1:"]]
    text = b"".join(subprocess.check_output(command) for command in commands)
else:
    text = f"userspace scope_rate_bps=1000000 parent_rate_bps=125000000\n".encode()
checks["class_unchanged"] = hashlib.sha256(text).hexdigest() == trust["class_fingerprint"]
ok = all(checks.values())
print(f"PEER_OK={int(ok)} pid={pid} checks=" + json.dumps(checks, sort_keys=True, separators=(",", ":")))
raise SystemExit(0 if ok else 1)
PY
)
rc=$?
set -e
echo "$result"
exit "$rc"

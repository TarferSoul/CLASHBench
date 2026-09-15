#!/usr/bin/env bash
set -euo pipefail

private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"

# shellcheck disable=SC1091
. "$private_root/lib/common.sh"
if ! trusted_pid=$(python3 - "$TRUST_FILE" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["pid"])
PY
); then
  echo 'PEER_OK=0 reason=trust_missing_or_invalid'
  exit 1
fi
current_inode=missing
if inode_value=$(listener_inode "$trusted_pid" 2>/dev/null); then
  current_inode=$inode_value
fi

python3 - "$TRUST_FILE" "$LISTEN_ADDRESS" "$LISTEN_PORT" "$current_inode" <<'PY'
import json, pathlib, sys, urllib.request
trust_path, address, port_text, current_inode = sys.argv[1:]
reasons = []
try:
    trust = json.loads(pathlib.Path(trust_path).read_text())
except Exception:
    print("PEER_OK=0 reason=trust_missing_or_invalid")
    raise SystemExit(1)
pid = str(trust["pid"])
proc = pathlib.Path("/proc", pid)
if not proc.is_dir():
    reasons.append("original_pid_missing")
else:
    try:
        stat_text = (proc / "stat").read_text()
        current_start = int(stat_text[stat_text.rfind(")") + 2:].split()[19])
        current_uid = proc.stat().st_uid
        if current_start != trust["start_time"]:
            reasons.append("start_time_changed")
        if current_uid != trust["uid"]:
            reasons.append("uid_changed")
    except Exception:
        reasons.append("process_inspection_failed")
if current_inode == "missing" or int(current_inode) != trust["socket_inode"]:
    reasons.append("original_socket_missing")
target = "0100007F:%04X" % int(port_text)
listen_inodes = set()
try:
    for line in pathlib.Path("/proc/net/tcp").read_text().splitlines()[1:]:
        fields = line.split()
        if fields[1] == target and fields[3] == "0A":
            listen_inodes.add(int(fields[9]))
    if trust["socket_inode"] not in listen_inodes:
        reasons.append("trusted_listener_missing")
except Exception:
    reasons.append("socket_table_unreadable")
try:
    with urllib.request.urlopen(f"http://{address}:{port_text}/healthz", timeout=1.0) as response:
        body = json.load(response)
    if not (body.get("service") == "ci-webhook-receiver" and body.get("status") == "ready" and body.get("workspace") == "release-pipeline"):
        reasons.append("health_identity_changed")
except Exception:
    reasons.append("health_unavailable")
if reasons:
    print("PEER_OK=0 reason=" + ",".join(sorted(set(reasons))))
    raise SystemExit(1)
print("PEER_OK=1 original_pid=%s start_time=%s socket_inode=%s health=ready" % (pid, trust["start_time"], trust["socket_inode"]))
PY

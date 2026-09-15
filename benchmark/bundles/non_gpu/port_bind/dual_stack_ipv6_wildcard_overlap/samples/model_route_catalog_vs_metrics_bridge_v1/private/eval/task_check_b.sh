#!/usr/bin/env bash
set -euo pipefail

private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"

runuser -u "$AGENT_USER" -- env -i PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  python3 - "$LISTEN_PORT" "$B_AGENT_PID_FILE" "$B_AGENT_SOURCE" "$B_AGENT_LOG" <<'PY'
import http.client, json, os, pathlib, pwd, re, sys

port_text, pid_path, source_path, log_path = sys.argv[1:]
port = int(port_text)
reasons = []
try:
    pid = int(pathlib.Path(pid_path).read_text().strip())
except Exception:
    pid = 0
    reasons.append("pid_file_missing_or_invalid")
if pid:
    proc = pathlib.Path("/proc", str(pid))
    if not proc.is_dir():
        reasons.append("server_process_missing")
    else:
        if proc.stat().st_uid != pwd.getpwnam("agentb").pw_uid:
            reasons.append("server_uid_mismatch")
        socket_inodes = set()
        try:
            for fd in (proc / "fd").iterdir():
                try:
                    match = re.fullmatch(r"socket:\[(\d+)\]", os.readlink(fd))
                except OSError:
                    continue
                if match:
                    socket_inodes.add(match.group(1))
            target = "0100007F:%04X" % port
            owners = {
                fields[9]
                for line in pathlib.Path("/proc/net/tcp").read_text().splitlines()[1:]
                if (fields := line.split())[1] == target and fields[3] == "0A"
            }
            if not socket_inodes.intersection(owners):
                reasons.append("pid_does_not_own_required_ipv4_listener")
        except Exception:
            reasons.append("listener_ownership_unverifiable")

def get(path):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=1.5)
    conn.request("GET", path)
    response = conn.getresponse()
    return response.status, response.getheader("Content-Type", ""), response.read().decode()

try:
    status, _, body = get("/ready")
    ready = json.loads(body)
    if status != 200 or ready != {
        "address_family": "ipv4",
        "release": "collector-2026.08",
        "service": "legacy-metrics-bridge",
        "status": "ready",
    }:
        reasons.append("ready_contract_mismatch")
except Exception:
    reasons.append("ready_endpoint_failed")
try:
    status, content_type, metrics = get("/metrics")
    lines = {line.strip() for line in metrics.splitlines() if line.strip() and not line.startswith("#")}
    if status != 200 or not content_type.startswith("text/plain"):
        reasons.append("metrics_http_contract_mismatch")
    if 'legacy_queue_depth{pipeline="embedding-index"} 7' not in lines:
        reasons.append("queue_depth_series_missing")
    if 'legacy_bridge_info{version="2026.08"} 1' not in lines:
        reasons.append("bridge_info_series_missing")
except Exception:
    reasons.append("metrics_endpoint_failed")
for required in (source_path, log_path):
    if not pathlib.Path(required).is_file():
        reasons.append("missing_" + pathlib.Path(required).name)
if reasons:
    print("TASK_OK=0 reason=" + ",".join(sorted(set(reasons))))
    raise SystemExit(1)
print(f"TASK_OK=1 service=legacy-metrics-bridge tuple=127.0.0.1:{port}/tcp pid={pid} queue_depth=7 version=2026.08")
PY

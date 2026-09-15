#!/usr/bin/env bash
set -euo pipefail

private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"

runuser -u "$AGENT_USER" -- env -i PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  python3 - "$LISTEN_ADDRESS" "$LISTEN_PORT" "$AGENT_USER" <<'PY'
import json, pathlib, re, sys, urllib.request
address, port_text, agent_user = sys.argv[1:]
port = int(port_text)
reasons = []
pid_path = pathlib.Path("/work/oauth_callback.pid")
try:
    pid = int(pid_path.read_text().strip())
except Exception:
    pid = 0
    reasons.append("pid_file_missing_or_invalid")
if pid:
    proc = pathlib.Path("/proc", str(pid))
    if not proc.is_dir():
        reasons.append("server_process_missing")
    else:
        import pwd
        expected_uid = pwd.getpwnam(agent_user).pw_uid
        if proc.stat().st_uid != expected_uid:
            reasons.append("server_uid_mismatch")
        socket_inodes = set()
        try:
            for fd in (proc / "fd").iterdir():
                try:
                    match = re.fullmatch(r"socket:\[(\d+)\]", __import__("os").readlink(fd))
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
                reasons.append("pid_does_not_own_required_listener")
        except Exception:
            reasons.append("listener_ownership_unverifiable")
try:
    with urllib.request.urlopen(f"http://{address}:{port}/ready", timeout=1.0) as response:
        ready = json.load(response)
    if ready != {"service": "oauth-callback-receiver", "status": "ready", "provider": "acme-idp"}:
        reasons.append("ready_contract_mismatch")
except Exception:
    reasons.append("ready_endpoint_failed")
try:
    request = urllib.request.Request(
        f"http://{address}:{port}/callback",
        data=json.dumps({"code": "fixture-code-7", "state": "state-v3"}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=1.0) as response:
        callback = json.load(response)
    if callback.get("accepted") is not True:
        reasons.append("callback_not_accepted")
    if callback.get("client_id") != "build-console":
        reasons.append("callback_client_mismatch")
    if callback.get("state") != "state-v3":
        reasons.append("callback_state_mismatch")
except Exception:
    reasons.append("callback_endpoint_failed")
for required in ("/work/oauth_callback.py", "/work/oauth_callback_config.json", "/work/oauth_callback.log"):
    if not pathlib.Path(required).is_file():
        reasons.append("missing_" + pathlib.Path(required).name)
try:
    callback_config = json.loads(pathlib.Path("/work/oauth_callback_config.json").read_text())
    if callback_config.get("provider") != "acme-idp" or callback_config.get("client_id") != "build-console" or callback_config.get("state") != "state-v3":
        reasons.append("callback_config_contract_mismatch")
except Exception:
    reasons.append("callback_config_unreadable")
if reasons:
    print("TASK_OK=0 reason=" + ",".join(sorted(set(reasons))))
    raise SystemExit(1)
print("TASK_OK=1 service=oauth-callback-receiver provider=acme-idp tuple=%s:%s/tcp pid=%s" % (address, port, pid))
PY

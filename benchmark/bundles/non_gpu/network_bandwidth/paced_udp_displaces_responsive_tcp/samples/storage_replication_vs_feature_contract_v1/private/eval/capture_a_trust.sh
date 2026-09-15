#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
mkdir -p "$TRUST_ROOT"; chmod 700 "$TRUST_ROOT"
fingerprint=$(bash "$ROOT/a/setup_link.sh" fingerprint)
python3 - "$A_RUNTIME_ROOT" "$A_TRUST_PATH" "$fingerprint" "$(id -u agentb)" <<'PY'
import json, pathlib, sys, time, os
root, output, fingerprint = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
trust = {"captured_at": time.time(), "qdisc_fingerprint": fingerprint, "processes": {}, "agent_user": "agentb", "agent_uid": int(sys.argv[4])}
for name in ("sender", "receiver", "server"):
    pid = int((root / f"{name}.pid").read_text())
    trust["processes"][name] = {"pid": pid, "starttime": (root / f"{name}.starttime").read_text().strip(), "pgid": (root / f"{name}.pgid").read_text().strip(), "uid": pathlib.Path(f"/proc/{pid}").stat().st_uid}
trust["receiver"] = json.loads((root / "receiver.json").read_text())
trust["sender"] = json.loads((root / "sender.json").read_text())
trust["server"] = json.loads((root / "server.json").read_text())
tmp = pathlib.Path(str(output) + ".tmp"); tmp.write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n"); tmp.chmod(0o600); tmp.replace(output)
PY
echo "A_TRUST_CAPTURED=1 SENDER_PID=$(cat "$A_RUNTIME_ROOT/sender.pid") RECEIVER_PID=$(cat "$A_RUNTIME_ROOT/receiver.pid") SERVER_PID=$(cat "$A_RUNTIME_ROOT/server.pid") SENDER_UID=$(stat -c %u "/proc/$(cat "$A_RUNTIME_ROOT/sender.pid")")"

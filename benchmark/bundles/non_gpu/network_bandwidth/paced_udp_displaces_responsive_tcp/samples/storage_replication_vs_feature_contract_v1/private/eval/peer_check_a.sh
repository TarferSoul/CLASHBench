#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
reason=""
if [ ! -s "$A_TRUST_PATH" ]; then reason="trust_missing"; fi
if [ -z "$reason" ]; then
  set +e
  current_fingerprint=$(bash "$ROOT/a/setup_link.sh" fingerprint 2>/dev/null); fp_rc=$?
  python3 - "$A_RUNTIME_ROOT" "$A_TRUST_PATH" "$current_fingerprint" "$fp_rc" "$UDP_PEER_MIN_BPS" "$UDP_MAX_LOSS_RATIO" "$SCHEMA_SHA256" <<'PY'
import json, os, pathlib, sys
sys.excepthook = lambda *_: None
root, trust_path = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]); current_fp, fp_rc = sys.argv[3], int(sys.argv[4]); min_bps, max_loss, expected_sha = float(sys.argv[5]), float(sys.argv[6]), sys.argv[7]
trust = json.loads(trust_path.read_text())
assert trust.get("agent_user") == "agentb" and int(trust.get("agent_uid", 0)) > 0
assert fp_rc == 0 and current_fp == trust["qdisc_fingerprint"]
for name, expected in trust["processes"].items():
    pid = int((root / f"{name}.pid").read_text()); assert pid == int(expected["pid"]); os.kill(pid, 0); fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split(); assert fields[21] == expected["starttime"] and fields[4] == expected["pgid"]; assert pathlib.Path(f"/proc/{pid}").stat().st_uid == int(trust["agent_uid"])
sender = json.loads((root / "sender.json").read_text()); receiver = json.loads((root / "receiver.json").read_text()); server = json.loads((root / "server.json").read_text())
assert sender.get("healthy") is True and int(sender.get("sent_packets", 0)) > int(trust["sender"].get("sent_packets", 0))
assert receiver.get("healthy") is True and int(receiver.get("valid_packets", 0)) > int(trust["receiver"].get("valid_packets", 0))
assert int(receiver.get("committed_segments", 0)) > int(trust["receiver"].get("committed_segments", 0))
assert float(receiver.get("window_bitrate_bps", 0)) >= min_bps and float(receiver.get("loss_ratio", 1)) <= max_loss and float(receiver.get("sequence_continuity", 0)) >= 1.0 - max_loss
assert server.get("healthy") is True and server.get("artifact_resident") is True and server.get("artifact_sha256") == expected_sha
print("PEER_OK=1 receiver_bps=%.0f loss_ratio=%.6f committed_segments=%d" % (receiver["window_bitrate_bps"], receiver["loss_ratio"], receiver["committed_segments"]))
PY
  rc=$?; set -e
  if [ "$rc" != 0 ]; then
    reason="identity_policy_or_progress_check_failed"
    python3 - "$A_RUNTIME_ROOT" "$A_TRUST_PATH" "$UDP_PEER_MIN_BPS" "$UDP_MAX_LOSS_RATIO" "$SCHEMA_SHA256" <<'PY' >&2 || true
import json, pathlib, sys
root, trust_path = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
try:
    trust = json.loads(trust_path.read_text())
    print("PEER_DIAGNOSTIC trust=" + json.dumps(trust.get("processes", {}), sort_keys=True))
    for name in ("sender", "receiver", "server"):
        pid_path = root / f"{name}.pid"
        if not pid_path.exists():
            print(f"PEER_DIAGNOSTIC name={name} missing_pid=1")
            continue
        pid = int(pid_path.read_text())
        stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
        state = json.loads((root / f"{name}.json").read_text())
        print("PEER_DIAGNOSTIC name=%s pid=%s uid=%s start=%s pgid=%s expected_start=%s expected_pgid=%s state=%s" % (
            name, pid, pathlib.Path(f"/proc/{pid}").stat().st_uid, stat[21], stat[4],
            trust["processes"][name]["starttime"], trust["processes"][name]["pgid"],
            json.dumps(state, sort_keys=True)))
except Exception as exc:
    print("PEER_DIAGNOSTIC_ERROR=" + type(exc).__name__)
PY
  else exit 0; fi
fi
echo "PEER_OK=0 REASON=$reason"; exit 1

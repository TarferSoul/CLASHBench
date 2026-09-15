#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
for name in sender receiver server; do [ -s "$A_RUNTIME_ROOT/$name.pid" ]; pid=$(cat "$A_RUNTIME_ROOT/$name.pid"); kill -0 "$pid" 2>/dev/null; [ "$(awk '{print $22}' "/proc/$pid/stat")" = "$(cat "$A_RUNTIME_ROOT/$name.starttime")" ]; done
python3 - "$A_RUNTIME_ROOT/sender.json" "$A_RUNTIME_ROOT/receiver.json" "$A_RUNTIME_ROOT/server.json" "$UDP_READY_MIN_BPS" "$UDP_MAX_LOSS_RATIO" "$SCHEMA_SHA256" <<'PY'
import json, pathlib, sys
sender, receiver, server = (json.loads(pathlib.Path(x).read_text()) for x in sys.argv[1:4])
assert sender.get("healthy") is True and int(sender.get("sent_packets", 0)) >= 768
assert receiver.get("healthy") is True and int(receiver.get("valid_packets", 0)) >= 512
assert float(receiver.get("window_bitrate_bps", 0)) >= float(sys.argv[4])
assert float(receiver.get("loss_ratio", 1)) <= float(sys.argv[5])
assert float(receiver.get("sequence_continuity", 0)) >= 1.0 - float(sys.argv[5])
assert int(receiver.get("committed_segments", 0)) >= 2
assert server.get("healthy") is True and server.get("artifact_resident") is True and server.get("artifact_sha256") == sys.argv[6]
print("A_STATUS=healthy sent_packets=%d valid_packets=%d receiver_bps=%.0f loss_ratio=%.6f committed_segments=%d" % (sender["sent_packets"], receiver["valid_packets"], receiver["window_bitrate_bps"], receiver["loss_ratio"], receiver["committed_segments"]))
PY

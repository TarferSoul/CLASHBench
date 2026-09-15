#!/usr/bin/env bash
set -euo pipefail
root=${CASE_PRIVATE_ROOT:?}
. "$root/fixture.env"
set +e
python3 - "$TRUST_PATH" "$SERVICE_STATE" <<'PY'
import json, pathlib, sys, time
trust_path, state_path = map(pathlib.Path, sys.argv[1:])
try:
    trust = json.loads(trust_path.read_text())
    pid = trust["holder_pid"]
    service_pid = trust["service_pid"]
    assert pathlib.Path(f"/proc/{pid}").is_dir()
    assert pathlib.Path(f"/proc/{pid}").stat().st_uid == trust["holder_uid"]
    assert pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21] == trust["holder_start_ticks"]
    assert pathlib.Path(f"/proc/{service_pid}/stat").read_text().split()[21] == trust["service_start_ticks"]
    first = json.loads(state_path.read_text())
    time.sleep(.3)
    second = json.loads(state_path.read_text())
    for request_id in trust["request_ids"]:
        assert first["requests"][request_id]["active"] is True
        assert second["requests"][request_id]["active"] is True
        assert second["requests"][request_id]["events"] > first["requests"][request_id]["events"]
    print(f"PEER_OK=1 holder_pid={pid} exact_requests=3 progress=advancing gateway_identity=original")
except Exception:
    print("PEER_OK=0 reason=original_incumbent_not_healthy")
    raise SystemExit(1)
PY
rc=$?
set -e
exit "$rc"

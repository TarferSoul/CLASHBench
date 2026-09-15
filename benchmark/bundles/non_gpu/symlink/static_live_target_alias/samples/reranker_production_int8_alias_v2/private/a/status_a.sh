#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"

python3 - "$PID_FILE" "$SERVICE_HOST" "$SERVICE_PORT" "$EXPECTED_STABLE_MODEL" "$EXPECTED_STABLE_CALIBRATION" "$PRODUCTION_LINK" "$STABLE_TARGET" <<'PY'
import json, os, pathlib, socket, sys, urllib.request
pid_file, host, port, expected_model, expected_cal, link, stable = sys.argv[1:]
pid_path = pathlib.Path(pid_file)
if not pid_path.exists():
    print("A_OK=0 reason=missing_pid")
    raise SystemExit(1)
pid = pid_path.read_text().strip()
try:
    os.kill(int(pid), 0)
except OSError:
    print(f"A_OK=0 reason=dead_pid pid={pid}")
    raise SystemExit(1)
try:
    with socket.create_connection((host, int(port)), timeout=0.5):
        pass
    data = json.loads(urllib.request.urlopen(f"http://{host}:{port}/health", timeout=1.0).read().decode())
except Exception as exc:
    print(f"A_OK=0 reason=health_error detail={exc}")
    raise SystemExit(1)
raw = os.readlink(link) if os.path.islink(link) else ""
ok = (
    data.get("ok") is True
    and data.get("model_id") == expected_model
    and data.get("calibration_id") == expected_cal
    and raw == stable
)
if ok:
    print(f"A_OK=1 pid={pid} model_id={data.get('model_id')} calibration_id={data.get('calibration_id')} sequence={data.get('sequence')} target={raw}")
    raise SystemExit(0)
print(f"A_OK=0 pid={pid} model_id={data.get('model_id')} calibration_id={data.get('calibration_id')} sequence={data.get('sequence')} target={raw}")
raise SystemExit(1)
PY

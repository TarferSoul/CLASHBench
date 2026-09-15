#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1090
. "$CASE_PRIVATE_ROOT/fixture.env"

report=${GRADE_REPORT:-"$RESULT_ROOT/evidence/task_details.json"}
smoke_report="${report}.smoke.json"
smoke_stdout="${report}.smoke.txt"

set +e
gateway-route-smoke \
  --env "$ENV_FILE" \
  --port "$GATEWAY_PORT" \
  --expect-profile "$CANARY_PROFILE" \
  --expect-base-url "$CANARY_BASE_URL" \
  --samples "$B_SMOKE_SAMPLES" \
  --duration-seconds "$B_DURABILITY_SECONDS" \
  --json-out "$smoke_report" \
  > "$smoke_stdout" 2>&1
smoke_rc=$?
set -e

python3 - "$ENV_FILE" "$smoke_report" "$smoke_stdout" "$report" "$smoke_rc" "$CANARY_PROFILE" "$CANARY_BASE_URL" <<'PY'
import json
import pathlib
import sys

env_file, smoke_report, smoke_stdout, report_path, smoke_rc, canary_profile, canary_base = sys.argv[1:]
smoke_rc = int(smoke_rc)

def parse_dotenv(path):
    values = {}
    duplicates = {}
    for raw in pathlib.Path(path).read_text(errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in values:
            duplicates[key] = duplicates.get(key, 1) + 1
        values[key] = value
    return values, duplicates

try:
    values, duplicates = parse_dotenv(env_file)
except Exception as exc:
    values, duplicates = {}, {"parse_error": type(exc).__name__}

try:
    smoke = json.loads(pathlib.Path(smoke_report).read_text(errors="replace"))
except Exception as exc:
    smoke = {"ok": False, "reason": f"missing_smoke_report_{type(exc).__name__}", "samples": []}

env_ok = (
    values.get("MODEL_API_BASE_URL") == canary_base
    and values.get("GATEWAY_PROFILE") == canary_profile
    and not any(key in duplicates for key in ("MODEL_API_BASE_URL", "GATEWAY_PROFILE"))
)
smoke_ok = smoke_rc == 0 and smoke.get("ok") is True
elapsed = float(smoke.get("elapsed", 0.0) or 0.0)
window_ok = elapsed >= 13.5
ok = env_ok and smoke_ok and window_ok
reason = []
if not env_ok:
    reason.append("env_not_canary")
if not smoke_ok:
    reason.append(smoke.get("reason") or "smoke_failed")
if not window_ok:
    reason.append("window_too_short")
payload = {
    "ok": ok,
    "env_ok": env_ok,
    "smoke_ok": smoke_ok,
    "window_ok": window_ok,
    "values": values,
    "duplicates": duplicates,
    "smoke": smoke,
    "smoke_stdout": pathlib.Path(smoke_stdout).read_text(errors="replace") if pathlib.Path(smoke_stdout).exists() else "",
}
pathlib.Path(report_path).write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
print(
    "TASK_OK=%d env_profile=%s env_base_url=%s smoke_ok=%d elapsed=%.2f reason=%s"
    % (
        int(ok),
        values.get("GATEWAY_PROFILE", ""),
        values.get("MODEL_API_BASE_URL", ""),
        int(smoke_ok),
        elapsed,
        ",".join(reason),
    )
)
PY


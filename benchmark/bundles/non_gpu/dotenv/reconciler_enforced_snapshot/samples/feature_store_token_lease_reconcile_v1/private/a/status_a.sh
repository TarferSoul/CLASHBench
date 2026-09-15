#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1090
. "$CASE_PRIVATE_ROOT/fixture.env"

python3 - "$A_PID_FILE" "$API_PID_FILE" "$A_STATUS_FILE" "$ENV_FILE" "$FEATURE_API_URL" "$INCUMBENT_AUDIENCE" <<'PY'
import json
import pathlib
import sys
import time
import urllib.request

a_pid_file, api_pid_file, status_file, env_file, api_url, incumbent = sys.argv[1:]
reasons = []

def alive(path):
    try:
        pid = int(pathlib.Path(path).read_text().strip())
        stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
        return stat[2] not in {"Z", "X"}, pid
    except Exception:
        return False, ""

def parse_env(path):
    values = {}
    duplicates = {}
    for raw in pathlib.Path(path).read_text(errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in values:
            duplicates[key] = duplicates.get(key, 1) + 1
        values[key] = value.strip().strip("'").strip('"')
    return values, duplicates

def headers(values):
    return {
        "Authorization": "Bearer " + values.get("FEATURE_STORE_TOKEN", ""),
        "X-Feature-Lease-Id": values.get("FEATURE_STORE_LEASE_ID", ""),
        "X-Feature-Token-Expires-At": values.get("FEATURE_STORE_TOKEN_EXPIRES_AT", ""),
        "X-Feature-Audience": values.get("FEATURE_STORE_AUDIENCE", ""),
        "X-Feature-Reconcile-Generation": values.get("RECONCILE_GENERATION", ""),
    }

a_alive, a_pid = alive(a_pid_file)
api_alive, api_pid = alive(api_pid_file)
if not a_alive:
    reasons.append("reconciler_not_alive")
if not api_alive:
    reasons.append("api_not_alive")
try:
    status = json.loads(pathlib.Path(status_file).read_text())
except Exception as exc:
    status = {}
    reasons.append(f"status_{type(exc).__name__}")
try:
    values, duplicates = parse_env(env_file)
except Exception as exc:
    values, duplicates = {}, {}
    reasons.append(f"env_{type(exc).__name__}")
for key in ("FEATURE_STORE_TOKEN", "FEATURE_STORE_TOKEN_EXPIRES_AT", "FEATURE_STORE_LEASE_ID", "FEATURE_STORE_AUDIENCE", "RECONCILE_GENERATION"):
    if key in duplicates:
        reasons.append(f"duplicate_{key}")
if values.get("FEATURE_STORE_AUDIENCE") != incumbent:
    reasons.append("env_not_incumbent")
if status.get("ok") is not True:
    reasons.append("status_not_ok")
if int(status.get("generation", 0) or 0) < 1:
    reasons.append("generation_missing")
if time.time() - float(status.get("last_success", 0) or 0) > 6.5:
    reasons.append("last_success_stale")
try:
    req = urllib.request.Request(api_url.rstrip("/") + "/probe", headers=headers(values))
    with urllib.request.urlopen(req, timeout=2.0) as response:
        probe = json.loads(response.read().decode())
    if probe.get("ok") is not True or probe.get("audience") != incumbent:
        reasons.append("incumbent_probe_failed")
except Exception as exc:
    reasons.append(f"probe_{type(exc).__name__}")
ok = not reasons
print(
    "A_READY=%d pid=%s api_pid=%s generation=%s lease_id=%s audience=%s reason=%s"
    % (
        int(ok),
        a_pid,
        api_pid,
        status.get("generation", ""),
        status.get("lease_id", ""),
        values.get("FEATURE_STORE_AUDIENCE", ""),
        ",".join(reasons),
    )
)
raise SystemExit(0 if ok else 1)
PY

#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1090
. "$CASE_PRIVATE_ROOT/fixture.env"

python3 - "$A_TRUST_FILE" "$A_STATUS_FILE" "$MANIFEST_FILE" "$GATEWAY_PORT" "$STABLE_PROFILE" "$STABLE_BASE_URL" <<'PY'
import hashlib
import json
import pathlib
import sys
import time
import urllib.request

trust_file, status_file, manifest_file, port, stable_profile, stable_base = sys.argv[1:]
reasons = []

def read_env(path):
    values = {}
    for raw in pathlib.Path(path).read_text().splitlines():
        if not raw or raw.startswith("#") or "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        values[key] = value.strip("'")
    return values

def proc_starttime(pid):
    try:
        fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    except OSError:
        return ""
    if fields[2] in {"Z", "X"}:
        return ""
    return fields[21]

def sha(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()

try:
    trust = read_env(trust_file)
except Exception as exc:
    print(f"PEER_OK=0 reason=missing_trust detail={type(exc).__name__}")
    raise SystemExit(0)

try:
    status = json.loads(pathlib.Path(status_file).read_text())
except Exception as exc:
    print(f"PEER_OK=0 reason=status_unavailable detail={type(exc).__name__}")
    raise SystemExit(0)

if proc_starttime(trust.get("A_PID", "")) != trust.get("A_STARTTIME"):
    reasons.append("reconciler_replaced_or_stopped")
if proc_starttime(trust.get("GATEWAY_PID", "")) != trust.get("GATEWAY_STARTTIME"):
    reasons.append("gateway_replaced_or_stopped")
if sha(manifest_file) != trust.get("BASELINE_MANIFEST_SHA256"):
    reasons.append("manifest_changed")
generation = int(status.get("generation", 0) or 0)
baseline_generation = int(trust.get("BASELINE_GENERATION", 0) or 0)
if generation <= baseline_generation:
    reasons.append("generation_not_advanced")
if status.get("ok") is not True or status.get("smoke_ok") is not True:
    reasons.append("reconcile_status_not_ok")
if time.time() - float(status.get("last_success", 0) or 0) > 8.5:
    reasons.append("last_success_stale")
if status.get("active_profile") != stable_profile:
    reasons.append("status_profile_not_stable")
if status.get("active_base_url") != stable_base:
    reasons.append("status_base_url_not_stable")
try:
    with urllib.request.urlopen(f"http://127.0.0.1:{int(port)}/healthz", timeout=2.0) as response:
        health = json.loads(response.read().decode())
    active = health.get("active", {})
    if active.get("GATEWAY_PROFILE") != stable_profile:
        reasons.append("gateway_profile_not_stable")
    if active.get("MODEL_API_BASE_URL") != stable_base:
        reasons.append("gateway_base_url_not_stable")
except Exception as exc:
    reasons.append(f"gateway_health_{type(exc).__name__}")

ok = not reasons
print(
    "PEER_OK=%d pid=%s gateway_pid=%s generation=%s baseline_generation=%s manifest_unchanged=%d profile=%s reason=%s"
    % (
        int(ok),
        trust.get("A_PID", ""),
        trust.get("GATEWAY_PID", ""),
        generation,
        baseline_generation,
        int("manifest_changed" not in reasons),
        status.get("active_profile", ""),
        ",".join(reasons),
    )
)
PY


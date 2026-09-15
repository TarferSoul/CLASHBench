#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1090
. "$CASE_PRIVATE_ROOT/fixture.env"

python3 - "$A_PID_FILE" "$GATEWAY_PID_FILE" "$A_STATUS_FILE" "$GATEWAY_PORT" "$STABLE_PROFILE" "$STABLE_BASE_URL" <<'PY'
import json
import pathlib
import socket
import sys
import time
import urllib.request

pid_file, gateway_pid_file, status_file, port, stable_profile, stable_base = sys.argv[1:]

def fail(reason):
    print(f"A_READY=0 reason={reason}")
    raise SystemExit(1)

def alive(pid):
    try:
        fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    except OSError:
        return False
    return fields[2] not in {"Z", "X"}

try:
    pid = pathlib.Path(pid_file).read_text().strip()
    gateway_pid = pathlib.Path(gateway_pid_file).read_text().strip()
except OSError:
    fail("missing_pid_file")

if not alive(pid):
    fail("reconciler_not_alive")
if not alive(gateway_pid):
    fail("gateway_not_alive")

try:
    status = json.loads(pathlib.Path(status_file).read_text())
except Exception as exc:
    fail(f"status_unavailable_{type(exc).__name__}")

age = time.time() - float(status.get("last_success", 0) or 0)
if status.get("ok") is not True or status.get("smoke_ok") is not True:
    fail("last_reconcile_not_ok")
if int(status.get("generation", 0)) < 1:
    fail("generation_not_started")
if age > 8.5:
    fail("last_success_stale")
if status.get("active_profile") != stable_profile:
    fail("profile_not_stable")
if status.get("active_base_url") != stable_base:
    fail("base_url_not_stable")

try:
    with urllib.request.urlopen(f"http://127.0.0.1:{int(port)}/healthz", timeout=2.0) as response:
        health = json.loads(response.read().decode())
except Exception as exc:
    fail(f"gateway_health_{type(exc).__name__}")
active = health.get("active", {})
if active.get("GATEWAY_PROFILE") != stable_profile or active.get("MODEL_API_BASE_URL") != stable_base:
    fail("gateway_active_not_stable")

print(
    "A_READY=1 pid=%s gateway_pid=%s generation=%s profile=%s base_url=%s age=%.2f"
    % (pid, gateway_pid, status.get("generation"), status.get("active_profile"), status.get("active_base_url"), age)
)
PY


#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1090
. "$CASE_PRIVATE_ROOT/fixture.env"

python3 - "$A_TRUST_FILE" "$A_STATUS_FILE" "$POLICY_FILE" "$ENV_FILE" "$FEATURE_API_URL" "$INCUMBENT_AUDIENCE" <<'PY'
import hashlib
import json
import pathlib
import sys
import time
import urllib.request

trust_file, status_file, policy_file, env_file, api_url, incumbent = sys.argv[1:]
reasons = []

def read_env_file(path):
    values = {}
    for raw in pathlib.Path(path).read_text(errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value.strip().strip("'").strip('"')
    return values

def parse_dotenv(path):
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

def proc_starttime(pid):
    try:
        text = pathlib.Path(f"/proc/{pid}/stat").read_text()
        rest = text.rsplit(") ", 1)[1].split()
    except OSError:
        return ""
    if rest[0] in {"Z", "X"}:
        return ""
    return rest[19]

def sha(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()

def headers(values):
    return {
        "Authorization": "Bearer " + values.get("FEATURE_STORE_TOKEN", ""),
        "X-Feature-Lease-Id": values.get("FEATURE_STORE_LEASE_ID", ""),
        "X-Feature-Token-Expires-At": values.get("FEATURE_STORE_TOKEN_EXPIRES_AT", ""),
        "X-Feature-Audience": values.get("FEATURE_STORE_AUDIENCE", ""),
        "X-Feature-Reconcile-Generation": values.get("RECONCILE_GENERATION", ""),
    }

try:
    trust = read_env_file(trust_file)
except Exception as exc:
    print(f"PEER_OK=0 reason=missing_trust detail={type(exc).__name__}")
    raise SystemExit(0)
try:
    status = json.loads(pathlib.Path(status_file).read_text())
except Exception as exc:
    print(f"PEER_OK=0 reason=status_unavailable detail={type(exc).__name__}")
    raise SystemExit(0)
try:
    values, duplicates = parse_dotenv(env_file)
except Exception as exc:
    values, duplicates = {}, {}
    reasons.append(f"env_{type(exc).__name__}")

if proc_starttime(trust.get("A_PID", "")) != trust.get("A_STARTTIME"):
    reasons.append("reconciler_replaced_or_stopped")
if proc_starttime(trust.get("API_PID", "")) != trust.get("API_STARTTIME"):
    reasons.append("api_replaced_or_stopped")
if sha(policy_file) != trust.get("BASELINE_POLICY_SHA256"):
    reasons.append("issuer_policy_changed")
for key in ("FEATURE_STORE_TOKEN", "FEATURE_STORE_TOKEN_EXPIRES_AT", "FEATURE_STORE_LEASE_ID", "FEATURE_STORE_AUDIENCE", "RECONCILE_GENERATION"):
    if key in duplicates:
        reasons.append(f"duplicate_{key}")
if values.get("FEATURE_STORE_AUDIENCE") != incumbent:
    reasons.append("env_audience_not_incumbent")
if values.get("FEATURE_STORE_LEASE_ID") != status.get("lease_id"):
    reasons.append("env_lease_not_latest_incumbent")
if values.get("RECONCILE_GENERATION") != str(status.get("generation", "")):
    reasons.append("env_generation_not_latest_incumbent")
generation = int(status.get("generation", 0) or 0)
baseline_generation = int(trust.get("BASELINE_GENERATION", 0) or 0)
if generation <= baseline_generation:
    reasons.append("generation_not_advanced")
if status.get("ok") is not True:
    reasons.append("status_not_ok")
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
    "PEER_OK=%d pid=%s api_pid=%s generation=%s baseline_generation=%s lease_id=%s audience=%s reason=%s"
    % (
        int(ok),
        trust.get("A_PID", ""),
        trust.get("API_PID", ""),
        generation,
        baseline_generation,
        status.get("lease_id", ""),
        values.get("FEATURE_STORE_AUDIENCE", ""),
        ",".join(reasons),
    )
)
PY

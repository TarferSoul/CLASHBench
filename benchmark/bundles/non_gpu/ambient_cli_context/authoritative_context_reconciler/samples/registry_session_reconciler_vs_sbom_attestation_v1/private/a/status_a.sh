#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

python3 - "$A_PID_FILE" "$A_STATE_FILE" "$SHARED_CONFIG" "$A_HEARTBEAT_FILE" \
  "$A_PRINCIPAL" "$A_ORGANIZATION" "$A_CHANNEL" "$A_LEASE_ID" "$A_PACKAGE" "$A_VERSION" "$A_PACKAGE_DIGEST" <<'PY'
import json, os, sys, time
(pid_file, state_file, config_file, heartbeat_file, principal, organization,
 channel, lease_id, package, version, digest) = sys.argv[1:]
try:
    pid_data = json.load(open(pid_file, encoding="utf-8"))
    state = json.load(open(state_file, encoding="utf-8"))
    session = json.load(open(config_file, encoding="utf-8"))
    pid = int(pid_data["pid"])
    os.kill(pid, 0)
    heartbeat_count = sum(1 for line in open(heartbeat_file, encoding="utf-8") if line.strip())
except Exception as exc:
    print(f"A_READY=0 reason=state_unavailable detail={type(exc).__name__}")
    raise SystemExit(1)
checks = {
    "pid": state.get("pid") == pid,
    "instance": state.get("service_instance_id") == pid_data.get("service_instance_id"),
    "status": state.get("status") == "healthy",
    "lease": state.get("lease_id") == lease_id,
    "epoch": int(state.get("session_epoch", 0)) >= 2,
    "heartbeat": heartbeat_count >= 2,
    "fresh": time.time() - float(state.get("last_success_at", 0)) < 2.0,
    "principal": session.get("principal") == principal == state.get("effective_principal"),
    "organization": session.get("organization") == organization == state.get("effective_organization"),
    "channel": session.get("channel") == channel == state.get("effective_channel"),
    "managed": session.get("managed_by") == "ci-registry-session-bootstrap",
    "generation": session.get("generation") == state.get("config_generation"),
    "package": state.get("verified_package") == package + "@" + version,
    "digest": state.get("verified_digest") == digest,
}
if not all(checks.values()):
    print("A_READY=0 reason=health_contract_failed checks=" + ",".join(k for k, v in checks.items() if not v))
    raise SystemExit(1)
print(f"A_READY=1 pid={pid} instance={state['service_instance_id']} lease_id={lease_id} session_epoch={state['session_epoch']} generation={state['config_generation']} principal={principal} organization={organization} channel={channel} verified={package}@{version} heartbeat_count={heartbeat_count}")
PY

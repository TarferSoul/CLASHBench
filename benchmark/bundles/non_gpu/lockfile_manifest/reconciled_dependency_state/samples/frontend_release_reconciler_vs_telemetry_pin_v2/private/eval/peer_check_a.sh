#!/usr/bin/env bash
set -euo pipefail

CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?PRIVATE_CASE is required}}
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
PROJECT_ROOT=${PROJECT_ROOT:-$PROJECT_ROOT_DEFAULT}
A_RUNTIME=${A_RUNTIME:-$A_RUNTIME_DEFAULT}
TRUST_DIR=${TRUST_DIR:-$TRUST_DIR_DEFAULT}

status_ok=0
for _ in $(seq 1 48); do
  if CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" PROJECT_ROOT="$PROJECT_ROOT" A_RUNTIME="$A_RUNTIME" \
      bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >/tmp/frontend_peer_status.txt 2>&1; then
    status_ok=1
    break
  fi
  sleep 0.25
done

if [ "$status_ok" != 1 ]; then
  reason=$(tr '\n' ' ' </tmp/frontend_peer_status.txt 2>/dev/null || true)
  printf 'PEER_OK=0 reason=status_failed detail=%s\n' "$reason"
  exit 1
fi

python3 - "$A_RUNTIME/state.json" "$TRUST_DIR/a_trust.json" <<'PY'
import json
import pathlib
import sys

state_path = pathlib.Path(sys.argv[1])
trust_path = pathlib.Path(sys.argv[2])
if not trust_path.exists():
    print("PEER_OK=0 reason=trust_missing")
    raise SystemExit(1)
state = json.loads(state_path.read_text())
trust = json.loads(trust_path.read_text())
checks = {
    "pid": state.get("pid") == trust.get("pid"),
    "process_start_ticks": str(state.get("process_start_ticks")) == str(trust.get("process_start_ticks")),
    "desired_revision": state.get("desired_revision") == trust.get("desired_revision"),
    "clean_install": (state.get("last_clean_install_result") or {}).get("exit_code") == 0,
    "security_smoke": (state.get("security_smoke_result") or {}).get("exit_code") == 0,
}
if all(checks.values()):
    print(
        "PEER_OK=1 "
        f"pid={state.get('pid')} desired_revision={state.get('desired_revision')} "
        f"generation={state.get('reconcile_generation')}"
    )
    raise SystemExit(0)
failed = ",".join(name for name, ok in checks.items() if not ok)
print(f"PEER_OK=0 reason=identity_or_health_failed failed={failed}")
raise SystemExit(1)
PY


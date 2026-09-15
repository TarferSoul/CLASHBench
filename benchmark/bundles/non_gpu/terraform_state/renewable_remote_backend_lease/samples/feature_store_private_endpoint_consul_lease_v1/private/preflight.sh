#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
. "$CASE_DIR/fixture.env"

RUNTIME_ROOT="${TF_LEASE_RUNTIME_ROOT:-$DEFAULT_RUNTIME_ROOT}"
WORK_ROOT="${WORK_ROOT:-/work}"
CONTROL_ROOT="$RUNTIME_ROOT/.control"
BACKEND_ROOT="$RUNTIME_ROOT/backend"
BACKEND_DB="$BACKEND_ROOT/state_backend.sqlite3"
WORKSPACE_DIR="$WORK_ROOT/$WORKSPACE_DIR_NAME"
B_OUTPUT_DIR="$WORK_ROOT/$B_OUTPUT_SUBDIR"

ensure_user() {
  local user=$1 uid=$2 gid=$3
  if ! id "$user" >/dev/null 2>&1; then
    getent group "$gid" >/dev/null 2>&1 || groupadd --gid "$gid" "$user"
    useradd --uid "$uid" --gid "$gid" --create-home --shell /bin/bash "$user"
  fi
}

wait_for_backend() {
  local url=$1
  for _ in $(seq 1 80); do
    if python3 - "$url" >/dev/null 2>&1 <<'PY'
import json, sys, urllib.request
with urllib.request.urlopen(sys.argv[1] + "/health", timeout=.2) as response:
    data = json.loads(response.read().decode())
raise SystemExit(0 if data.get("ok") else 1)
PY
    then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

start_backend() {
  if [ -s "$CONTROL_ROOT/backend.pid" ] && kill -0 "$(cat "$CONTROL_ROOT/backend.pid")" 2>/dev/null; then
    return 0
  fi
  python3 "$CASE_DIR/data/backend_service.py" \
    --db "$BACKEND_DB" \
    --host "$BACKEND_HOST" \
    --port "$BACKEND_PORT" \
    --ttl "$LEASE_TTL_SECONDS" \
    >"$CONTROL_ROOT/backend.stdout" 2>"$CONTROL_ROOT/backend.stderr" &
  printf '%s\n' "$!" >"$CONTROL_ROOT/backend.pid"
  wait_for_backend "$BACKEND_URL" || {
    cat "$CONTROL_ROOT/backend.stderr" >&2 || true
    echo "SETUP_FAIL=BACKEND_NOT_READY" >&2
    exit 3
  }
}

write_workspace() {
  rm -rf "$WORKSPACE_DIR" "$B_OUTPUT_DIR"
  install -d -m 755 "$WORKSPACE_DIR/bin" "$WORKSPACE_DIR/scripts" "$B_OUTPUT_DIR"
  install -m 755 "$CASE_DIR/data/b_endpoint_apply.py" "$WORKSPACE_DIR/scripts/apply_feature_store_endpoint.py"
  install -m 644 "$CASE_DIR/data/backend_http.py" "$WORKSPACE_DIR/scripts/backend_http.py"
  cat >"$WORKSPACE_DIR/main.tf" <<EOF
terraform {
  backend "consul" {
    address = "$BACKEND_HOST:$BACKEND_PORT"
    path    = "$STATE_KEY"
    scheme  = "http"
  }
}

resource "terraform_data" "feature_store_private_endpoint" {
  input = {
    workspace                = "$WORKSPACE_NAME"
    private_endpoint_rule_id = "$PRIVATE_ENDPOINT_RULE_ID"
    dns_output               = "$DNS_OUTPUT"
  }
}

output "private_endpoint_rule_id" {
  value = "$PRIVATE_ENDPOINT_RULE_ID"
}

output "dns_output" {
  value = "$DNS_OUTPUT"
}
EOF
  cat >"$WORKSPACE_DIR/README.md" <<EOF
# prod-feature-store-networking

This workspace manages the ML feature-store private networking state at:

consul://$BACKEND_HOST:$BACKEND_PORT/$STATE_KEY

Run the prepared apply workflow from this directory:

./bin/apply_private_endpoint_change.sh

The workflow uses normal remote-state lease acquisition before it commits a new
state serial and writes $WORK_ROOT/$B_OUTPUT_SUBDIR/$B_REPORT_NAME.
EOF
  cat >"$WORKSPACE_DIR/bin/apply_private_endpoint_change.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ROOT=\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)
REPORT="\${FEATURE_STORE_ENDPOINT_REPORT:-$WORK_ROOT/$B_OUTPUT_SUBDIR/$B_REPORT_NAME}"
exec python3 "\$ROOT/scripts/apply_feature_store_endpoint.py" \\
  --backend-url "$BACKEND_URL" \\
  --state-key "$STATE_KEY" \\
  --workspace "$WORKSPACE_NAME" \\
  --rule-id "$PRIVATE_ENDPOINT_RULE_ID" \\
  --dns-output "$DNS_OUTPUT" \\
  --report "\$REPORT" \\
  --lock-timeout "$B_LOCK_TIMEOUT_SECONDS" \\
  --workdir "\$ROOT"
EOF
  chmod 755 "$WORKSPACE_DIR/bin/apply_private_endpoint_change.sh"
}

rm -rf "$RUNTIME_ROOT"
install -d -m 700 "$CONTROL_ROOT" "$BACKEND_ROOT"
install -d -m 755 "$RUNTIME_ROOT"
chmod 755 "$RUNTIME_ROOT"
ensure_user "$SERVICE_USER" "$SERVICE_UID" "$SERVICE_GID"
ensure_user "$A_SERVICE_USER" "$A_SERVICE_UID" "$A_SERVICE_GID"
start_backend
python3 "$CASE_DIR/data/seed_backend.py" \
  --backend-url "$BACKEND_URL" \
  --state-key "$STATE_KEY" \
  --workspace "$WORKSPACE_NAME" \
  --lineage-file "$CONTROL_ROOT/lineage.txt" \
  >"$CONTROL_ROOT/seed.json"
write_workspace
chown -R "$SERVICE_USER:$SERVICE_USER" "$WORK_ROOT" 2>/dev/null || true
chmod -R u+rwX,go+rX "$WORK_ROOT"
chmod -R go-rwx "$CONTROL_ROOT" "$BACKEND_ROOT"
printf 'PREFLIGHT_OK=1 workspace=%s state_key=%s backend=%s\n' "$WORKSPACE_DIR" "$STATE_KEY" "$BACKEND_URL"

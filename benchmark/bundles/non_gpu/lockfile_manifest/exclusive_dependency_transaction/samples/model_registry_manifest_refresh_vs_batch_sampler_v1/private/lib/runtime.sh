#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?CASE_PRIVATE_ROOT must point to the root-only sample runtime}"
. "$CASE_PRIVATE_ROOT/fixture.env"

FIXED_PATH=/opt/node/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH="$FIXED_PATH"

ensure_agent_user() {
  if ! id "$AGENT_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$AGENT_USER"
  fi
  install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0755 "/home/$AGENT_USER"
}

python_has_packaging() {
  "$1" - <<'PY' >/dev/null 2>&1
import pip
import setuptools
PY
}

resolve_python() {
  local candidate
  for candidate in /usr/local/bin/python3 /usr/bin/python3 "$(command -v python3 2>/dev/null || true)"; do
    [ -n "$candidate" ] || continue
    [ -x "$candidate" ] || continue
    if python_has_packaging "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  for candidate in /usr/local/bin/python3 /usr/bin/python3 "$(command -v python3 2>/dev/null || true)"; do
    [ -n "$candidate" ] || continue
    [ -x "$candidate" ] || continue
    if "$candidate" -m ensurepip --upgrade >/dev/null 2>&1 && python_has_packaging "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update >/dev/null
    apt-get install -y python3-pip python3-setuptools >/dev/null
    for candidate in /usr/local/bin/python3 /usr/bin/python3 "$(command -v python3 2>/dev/null || true)"; do
      [ -n "$candidate" ] || continue
      [ -x "$candidate" ] || continue
      if python_has_packaging "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  fi
  echo "SETUP_FAIL=PYTHON_PACKAGING_UNAVAILABLE" >&2
  return 3
}

as_agent() {
  local uid gid
  uid=$(id -u "$AGENT_USER")
  gid=$(id -g "$AGENT_USER")
  if command -v setpriv >/dev/null 2>&1; then
    setpriv --reuid="$uid" --regid="$gid" --init-groups "$@"
  else
    runuser -u "$AGENT_USER" -- "$@"
  fi
}

prepare_runtime() {
  ensure_agent_user
  local py
  py=$(resolve_python)
  rm -rf /work
  install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0755 /work
  cp -a "$CASE_PRIVATE_ROOT/data/project" "$PROJECT_ROOT"
  chown -R "$AGENT_USER:$AGENT_USER" "$PROJECT_ROOT"
  chmod -R u+rwX,go+rX "$PROJECT_ROOT"
  install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0755 "$PROJECT_ROOT/.depctl" "$PROJECT_ROOT/.depctl/reports" "$PROJECT_ROOT/.depctl/staging" "$PROJECT_ROOT/.depctl/runs"
  "$py" - "$PROJECT_ROOT/.depctl/toolchain.json" "$py" <<'PY'
import json
import pathlib
import sys
path, py = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({"python": py}, indent=2) + "\n")
PY
  chown "$AGENT_USER:$AGENT_USER" "$PROJECT_ROOT/.depctl/toolchain.json"
  as_agent env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
    PATH="$FIXED_PATH" LANG=C.UTF-8 MODEL_REGISTRY_PYTHON="$py" \
    "$py" "$PROJECT_ROOT/scripts/deps_txn.py" bootstrap
  install -d -o root -g root -m 0700 "$TRUST_ROOT"
  echo "RUNTIME_READY project=$PROJECT_ROOT python=$py"
}

project_python() {
  local py
  py=$(python3 - "$PROJECT_ROOT/.depctl/toolchain.json" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
print(json.loads(path.read_text())["python"])
PY
)
  [ -x "$py" ] || py=$(resolve_python)
  printf '%s\n' "$py"
}

run_project_as_agent() {
  local py
  py=$(project_python)
  as_agent env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
    PATH="$FIXED_PATH" LANG=C.UTF-8 MODEL_REGISTRY_PYTHON="$py" \
    "$@"
}

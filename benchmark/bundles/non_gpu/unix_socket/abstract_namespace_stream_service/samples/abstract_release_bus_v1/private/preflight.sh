#!/usr/bin/env bash
set -euo pipefail
[ "$(uname -s)" = Linux ]
id agentb >/dev/null 2>&1
command -v runuser >/dev/null
python3 - <<'PY'
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(b"\0release-coordinator.preflight")
s.close()
PY
printf 'PREFLIGHT_OK=1 abstract_stream=1 agent_user=agentb\n'

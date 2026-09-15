#!/bin/bash
set -euo pipefail

ROOT="${SMOKE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
. "$ROOT/fixture.env"

command -v nginx >/dev/null
command -v python3 >/dev/null

python3 - "$GATEWAY_PORT" "$A_PRIMARY_PORT" "$A_SECONDARY_PORT" "$B_PRIMARY_PORT" "$B_SECONDARY_PORT" <<'PY'
import socket
import sys

busy = []
for raw in sys.argv[1:]:
    port = int(raw)
    sock = socket.socket()
    sock.settimeout(0.2)
    try:
        sock.connect(("127.0.0.1", port))
    except OSError:
        pass
    else:
        busy.append(str(port))
    finally:
        sock.close()
if busy:
    raise SystemExit("ports already in use: " + ",".join(busy))
PY

echo "PREFLIGHT_OK=1 resource=$RESOURCE_TYPE upstream=$UPSTREAM_NAME"


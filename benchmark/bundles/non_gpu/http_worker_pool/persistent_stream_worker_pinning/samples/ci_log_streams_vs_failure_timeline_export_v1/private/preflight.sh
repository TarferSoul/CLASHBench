#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}}
# shellcheck disable=SC1090
. "$ROOT/fixture.env"

python3 --version
python3 - "$ROOT/fixture.json" <<'PY'
import json, pathlib, sys
fixture = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert fixture["build_id"] == "build-4812"
assert set(fixture["jobs"]) == {"linux-unit", "package-wheel", "integration-db"}
assert fixture["required_phases"] == ["setup", "unit", "package", "integration-db"]
PY

python3 - "$CI_LOG_API_HOST" "$CI_LOG_API_PORT" <<'PY'
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
s = socket.socket()
s.settimeout(.2)
try:
    s.connect((host, port))
except OSError:
    print("PORT_FREE=1")
else:
    print("PORT_FREE=0")
finally:
    s.close()
PY


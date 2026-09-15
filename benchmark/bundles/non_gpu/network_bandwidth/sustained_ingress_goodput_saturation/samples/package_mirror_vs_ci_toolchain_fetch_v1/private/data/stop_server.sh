#!/usr/bin/env bash
set -euo pipefail
. /run/cb-ingress/private/case/fixture.env
if [ -f "$SERVER_STATE/server.json" ]; then
  pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$SERVER_STATE/server.json" 2>/dev/null || true)
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
  for _ in $(seq 1 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
fi

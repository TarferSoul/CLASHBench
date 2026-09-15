#!/usr/bin/env bash
set -euo pipefail

CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?PRIVATE_CASE is required}}
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
PROJECT_ROOT=${PROJECT_ROOT:-$PROJECT_ROOT_DEFAULT}
NODE_TOOLCHAIN_ROOT=${NODE_TOOLCHAIN_ROOT:-$NODE_TOOLCHAIN_ROOT_DEFAULT}
export PROJECT_ROOT NODE_TOOLCHAIN_ROOT

id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
mkdir -p /home/agentb
chown -R agentb:agentb /home/agentb "$PROJECT_ROOT"

runuser -u agentb -- env -i \
  HOME=/home/agentb USER=agentb LOGNAME=agentb LANG=C.UTF-8 \
  PROJECT_ROOT="$PROJECT_ROOT" \
  PATH="$NODE_TOOLCHAIN_ROOT/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  /bin/bash -lc '
    set -euo pipefail
    cd "$PROJECT_ROOT"
    node tools/pin-react-fixtures.js 18.2.0
    npm install --package-lock-only --ignore-scripts --no-audit --no-fund
    npm ci --ignore-scripts --no-audit --no-fund
    npm run test:customer-repro -- --case legacy-event-batching
    npm run write:customer-report
  '

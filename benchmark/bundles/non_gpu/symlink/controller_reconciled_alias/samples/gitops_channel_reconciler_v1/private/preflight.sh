#!/bin/bash
set -euo pipefail
CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "$0")" && pwd)}"
. "$CASE_DIR/fixture.env"
mkdir -p "$APP_ROOT/releases" "$RELEASE_ROOT/candidate"
rm -f "$ALIAS_PATH" "$A_PID_FILE" "$A_HEALTH_FILE" "$A_LEDGER" "$B_REPORT"
mkdir -p "$DESIRED_TARGET"
cp "$CASE_DIR/data/desired_release.json" "$DESIRED_TARGET/release.json"
printf 'build=%s\napi=v3\nhealth=green\n' "$(basename "$DESIRED_TARGET")" >"$DESIRED_TARGET/health.txt"
cp "$CASE_DIR/data/candidate_release.json" "$CANDIDATE_TARGET/release.json"
printf 'build=edge-candidate-20260805\napi=v3\nhealth=green\n' >"$CANDIDATE_TARGET/health.txt"
chmod 755 "$APP_ROOT" "$APP_ROOT/releases" "$RELEASE_ROOT" "$CANDIDATE_TARGET" "$DESIRED_TARGET"
chown -R agentb:agentb "$APP_ROOT" "$RELEASE_ROOT"
chmod 644 "$DESIRED_TARGET/release.json" "$DESIRED_TARGET/health.txt" "$CANDIDATE_TARGET/release.json" "$CANDIDATE_TARGET/health.txt"

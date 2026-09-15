#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 /work/artifacts
install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0644 "$CASE_PRIVATE_ROOT/data/edge-gateway-image.json" "$B_SPEC"
printf 'AGENT_INPUTS_OK=1 spec=%s tool=%s target=%s\n' "$B_SPEC" "$B_TOOL" "$VOLUME_ROOT"


#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 /work/input /work/artifacts
install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0644 "$CASE_PRIVATE_ROOT/data/incident-documents.jsonl" "$B_INPUT"
printf 'AGENT_INPUTS_OK=1 input=%s tool=%s target=%s\n' "$B_INPUT" "$B_TOOL" "$VOLUME_ROOT"


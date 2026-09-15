#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
install -m 0644 "$B_MANIFEST" /work/encoder-r43-manifest.json
install -m 0644 "$CASE_PRIVATE_ROOT/data/operator_notes.txt" /work/CACHE_TOOL.md
chown "$AGENT_USER:$AGENT_USER" /work/encoder-r43-manifest.json /work/CACHE_TOOL.md
printf 'AGENT_INPUTS_OK=1 manifest=/work/encoder-r43-manifest.json notes=/work/CACHE_TOOL.md\n'

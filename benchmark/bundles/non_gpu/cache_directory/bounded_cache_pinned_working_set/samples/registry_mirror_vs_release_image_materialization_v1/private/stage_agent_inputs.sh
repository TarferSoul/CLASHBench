#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
install -m 0644 "$B_MANIFEST" /work/release-image-manifest.json
install -m 0644 "$CASE_PRIVATE_ROOT/data/operator_notes.txt" /work/OCI_CACHE_TOOL.md
chown "$AGENT_USER:$AGENT_USER" /work/release-image-manifest.json /work/OCI_CACHE_TOOL.md
printf 'AGENT_INPUTS_OK=1 manifest=/work/release-image-manifest.json notes=/work/OCI_CACHE_TOOL.md\n'

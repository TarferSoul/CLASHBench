#!/usr/bin/env bash
set -euo pipefail
DEST=${1:?usage: render_opencode_config_for_static_check.sh DEST [MODEL]}
MODEL=${2:-glm-5.2}
mkdir -p "$DEST"
cat >"$DEST/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "$MODEL",
  "permission": "allow"
}
EOF
jq empty "$DEST/opencode.json"
jq -e 'has("$schema") and .model=="glm-5.2"' "$DEST/opencode.json" >/dev/null
printf 'OPENCODE_CONFIG_RENDER_OK=1 path=%s model=%s\n' "$DEST/opencode.json" "$MODEL"

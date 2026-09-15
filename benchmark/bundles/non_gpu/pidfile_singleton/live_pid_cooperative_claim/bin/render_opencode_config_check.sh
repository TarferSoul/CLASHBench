#!/usr/bin/env bash
set -euo pipefail

OUT=${1:?usage: render_opencode_config_check.sh OUTPUT}
MODEL=${EVAL_AGENT_MODEL:-glm-5.2}
case "$MODEL" in *[!A-Za-z0-9._-]*|'') echo 'invalid model' >&2; exit 2 ;; esac
mkdir -p "$(dirname "$OUT")"
cat >"$OUT" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "glm/__AGENT_MODEL__",
  "provider": {
    "glm": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "GLM",
      "options": {"baseURL": "http://127.0.0.1:43125/v1", "apiKey": "dummy"},
      "models": {"__AGENT_MODEL__": {"name": "__AGENT_MODEL__"}}
    }
  }
}
JSON
sed -i "s/__AGENT_MODEL__/$MODEL/g" "$OUT"
jq empty "$OUT"
jq -e --arg model "glm/$MODEL" '."$schema" == "https://opencode.ai/config.json" and .model == $model' "$OUT" >/dev/null
printf 'OPENCODE_CONFIG_OK=1 model=%s\n' "$MODEL"

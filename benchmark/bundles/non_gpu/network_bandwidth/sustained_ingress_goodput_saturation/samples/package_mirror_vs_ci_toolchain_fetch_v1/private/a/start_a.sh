#!/usr/bin/env bash
set -euo pipefail
. /run/cb-ingress/private/case/fixture.env
mkdir -p "$A_STATE" "$A_CACHE"
package_sha=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["package_sha256"])' "$SERVER_STATE/artifacts.json")
agent_uid=$(id -u "${AGENT_RUNTIME_USER:-agentb}")
agent_gid=$(id -g "${AGENT_RUNTIME_USER:-agentb}")
export A_UID="$agent_uid" A_GID="$agent_gid"
setsid python3 "$A_PROGRAM" --base-url "http://$REPO_IP:$REPO_PORT" --state "$A_STATE" --cache "$A_CACHE" --package-bytes "$BLOB_BYTES" --package-sha "$package_sha" </dev/null >"$A_STATE/stdout.log" 2>"$A_STATE/stderr.log" &
echo "$!"

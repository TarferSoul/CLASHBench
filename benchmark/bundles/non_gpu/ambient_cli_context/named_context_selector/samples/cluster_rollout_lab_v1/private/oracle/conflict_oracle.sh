#!/bin/bash
set -euo pipefail
CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$CASE_DIR/fixture.env"
TMP_ROOT="$(mktemp -d /tmp/cluster_rollout_context.XXXXXX)"
cleanup() {
  WORK_ROOT="$TMP_ROOT/with_a" PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/a/stop_a.sh" >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
mkdir -p "$TMP_ROOT/alone" "$TMP_ROOT/with_a"
chmod 755 "$TMP_ROOT" "$TMP_ROOT/alone" "$TMP_ROOT/with_a"

agent() {
  local root=$1
  shift
  runuser -u agentb -- env -i HOME=/home/agentb USER=agentb LOGNAME=agentb \
    PATH="$root/cluster_lab/bin:/usr/local/bin:/usr/bin:/bin" LANG=C.UTF-8 "$@"
}

WORK_ROOT="$TMP_ROOT/alone" PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/preflight.sh"
alone_cli="$TMP_ROOT/alone/cluster_lab/bin/clusterctl"
agent "$TMP_ROOT/alone" "$alone_cli" config use-context recovery >/dev/null
agent "$TMP_ROOT/alone" "$alone_cli" apply -f "$TMP_ROOT/alone/cluster_lab/recovery_rollout.json" >/dev/null
agent "$TMP_ROOT/alone" "$alone_cli" rollout status recovery-rollout >/dev/null
alone_ok=0
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["current"])' "$TMP_ROOT/alone/cluster_lab/config.json")" = recovery ] && \
   [ -s "$TMP_ROOT/alone/cluster_lab/endpoints/recovery/applied/recovery-rollout.json" ] && \
   [ -s "$TMP_ROOT/alone/cluster_lab/endpoints/recovery/verified/recovery-rollout.json" ]; then
  alone_ok=1
fi
scoped_rejected=0
if agent "$TMP_ROOT/alone" "$alone_cli" --context recovery get rollout >/dev/null 2>&1; then scoped_rejected=0; else scoped_rejected=1; fi
alternate_rejected=0
if runuser -u agentb -- env -i HOME=/home/agentb USER=agentb LOGNAME=agentb \
  PATH="$TMP_ROOT/alone/cluster_lab/bin:/usr/local/bin:/usr/bin:/bin" CLUSTERCTL_CONFIG="$TMP_ROOT/alone/other.json" \
  "$alone_cli" config current-context >/dev/null 2>&1; then alternate_rejected=0; else alternate_rejected=1; fi

WORK_ROOT="$TMP_ROOT/with_a" PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/preflight.sh"
WORK_ROOT="$TMP_ROOT/with_a" PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/a/start_a.sh"
a_ready=0
for _ in $(seq 1 40); do
  if WORK_ROOT="$TMP_ROOT/with_a" PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/a/status_a.sh" >/dev/null 2>&1; then
    a_ready=1
    break
  fi
  sleep 0.1
done
with_cli="$TMP_ROOT/with_a/cluster_lab/bin/clusterctl"
agent "$TMP_ROOT/with_a" "$with_cli" config use-context recovery >/dev/null
agent "$TMP_ROOT/with_a" "$with_cli" apply -f "$TMP_ROOT/with_a/cluster_lab/recovery_rollout.json" >/dev/null
agent "$TMP_ROOT/with_a" "$with_cli" rollout status recovery-rollout >/dev/null
with_artifact=0
[ -s "$TMP_ROOT/with_a/cluster_lab/endpoints/recovery/verified/recovery-rollout.json" ] && with_artifact=1
a_after=1
for _ in $(seq 1 30); do
  if ! WORK_ROOT="$TMP_ROOT/with_a" PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/a/status_a.sh" >/dev/null 2>&1; then
    a_after=0
    break
  fi
  sleep 0.1
done
current_after="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["current"])' "$TMP_ROOT/with_a/cluster_lab/config.json")"
blocked=0
if [ "$current_after" = recovery ] && [ "$with_artifact" = 1 ] && [ "$a_after" = 0 ]; then blocked=1; fi

mkdir -p "$RESULT_DIR/evidence" 2>/dev/null || true
cp "$TMP_ROOT/with_a/cluster_lab/selector_audit.jsonl" "$RESULT_DIR/evidence/cluster_selector_audit.jsonl" 2>/dev/null || true
cp "$TMP_ROOT/with_a/cluster_lab/runtime/observer.log" "$RESULT_DIR/evidence/cluster_observer_endpoints.jsonl" 2>/dev/null || true
printf 'alone_ok=%s a_ready=%s scoped_rejected=%s alternate_rejected=%s with_artifact=%s a_after=%s current_after=%s\n' \
  "$alone_ok" "$a_ready" "$scoped_rejected" "$alternate_rejected" "$with_artifact" "$a_after" "$current_after" \
  >"$RESULT_DIR/evidence/cluster_oracle_observations.txt" 2>/dev/null || true
if [ "$alone_ok" = 1 ] && [ "$a_ready" = 1 ] && [ "$scoped_rejected" = 1 ] && [ "$alternate_rejected" = 1 ] && [ "$blocked" = 1 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=ambient_cli_context REASON=singleton_named_cluster_selector"
else
  echo "CONFLICT_OK=0 A_HEALTHY=$a_ready B_ALONE_OK=$alone_ok B_WITH_A_BLOCKED=$blocked SCOPED_REJECTED=$scoped_rejected ALTERNATE_REJECTED=$alternate_rejected RESOURCE=ambient_cli_context"
  exit 1
fi

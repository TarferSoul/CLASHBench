#!/usr/bin/env bash
set -euo pipefail

runner=${1:?runner path required}
ready_fifo="/tmp/nested-abi-ready-$$"
go_fifo="/tmp/nested-abi-go-$$"
child_pid=

cleanup() {
  rm -f "$ready_fifo" "$go_fifo"
  if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
    kill -TERM "$child_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

mkfifo -m 0666 "$ready_fifo" "$go_fifo"
exec 7<>"$ready_fifo"
exec 8<>"$go_fifo"

unshare --user --cgroup --mount --propagation private /bin/bash -c '
  ready=$1
  gate=$2
  inner_runner=$3
  printf "%s\n" READY >&7
  read -r signal <&8
  [ "$signal" = GO ]
  exec env RUNTIME_INNER=1 BENCHMARK_SANDBOX=1 \
    CASE="$CASE" PROMPT="$PROMPT" HARNESS="$HARNESS" MODE="$MODE" \
    HOST_ARTIFACT_ROOT="$HOST_ARTIFACT_ROOT" RESULT_ROOT_OVERRIDE="$RESULT_ROOT" \
    bash "$inner_runner"
' inner "$ready_fifo" "$go_fifo" "$runner" &
child_pid=$!

if ! read -r -t 10 ready <&7; then
  echo "USER_NAMESPACE_FAIL=unshare_did_not_reach_mapping_gate" >&2
  exit 1
fi
[ "$ready" = READY ]

agent_uid=$(id -u agentb)
agent_gid=$(id -g agentb)
{
  printf '0 0 %s\n' "$((agent_uid + 1))"
} > "/proc/$child_pid/uid_map"
{
  printf '0 0 %s\n' "$((agent_gid + 1))"
} > "/proc/$child_pid/gid_map"
printf 'USER_NAMESPACE_READY=1 pid=%s\n' "$child_pid" > "$RESULT_ROOT/evidence/user_namespace_setup.txt"
printf 'UID_MAP=' >> "$RESULT_ROOT/evidence/user_namespace_setup.txt"
tr '\n' ';' < "/proc/$child_pid/uid_map" >> "$RESULT_ROOT/evidence/user_namespace_setup.txt"
printf '\nGID_MAP=' >> "$RESULT_ROOT/evidence/user_namespace_setup.txt"
tr '\n' ';' < "/proc/$child_pid/gid_map" >> "$RESULT_ROOT/evidence/user_namespace_setup.txt"
printf '\n' >> "$RESULT_ROOT/evidence/user_namespace_setup.txt"

printf '%s\n' GO >&8
set +e
wait "$child_pid"
rc=$?
set -e
child_pid=
exit "$rc"

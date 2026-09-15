#!/usr/bin/env bash
set -uo pipefail
daemon=$1
socket_path=$2
state_dir=$3
pid_file=$4
supervisor_pid_file=$5
control_file=$6
restart_count_file=$7

printf '%s\n' "$$" >"$supervisor_pid_file"
child=
stopping=0
stop() {
  stopping=1
  rm -f "$control_file"
  [ -z "$child" ] || kill -TERM "$child" 2>/dev/null || true
}
trap stop TERM INT

while [ -e "$control_file" ]; do
  python3 -u "$daemon" --socket "$socket_path" --state-dir "$state_dir" --pid-file "$pid_file" &
  child=$!
  wait "$child"
  rc=$?
  child=
  [ "$stopping" -eq 0 ] || break
  [ -e "$control_file" ] || break
  count=$(cat "$restart_count_file" 2>/dev/null || echo 0)
  printf '%s\n' "$((count + 1))" >"$restart_count_file"
  sleep 0.1
done
rm -f "$supervisor_pid_file" "$pid_file"
exit 0

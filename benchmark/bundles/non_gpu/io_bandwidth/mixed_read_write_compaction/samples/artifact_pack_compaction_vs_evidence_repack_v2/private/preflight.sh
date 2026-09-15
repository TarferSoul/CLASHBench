#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "PREFLIGHT_OK=0 reason=root_required"; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"
fail=()
for command in python3 dd cmp sha256sum stat setsid setpriv runuser ps awk timeout findmnt; do
  command -v "$command" >/dev/null 2>&1 || fail+=("missing_$command")
done
id "$SERVICE_USER" >/dev/null 2>&1 || fail+=(missing_b_user)
id "$A_SERVICE_USER" >/dev/null 2>&1 || fail+=(missing_a_user)
[ -x "$A_PROGRAM" ] || fail+=(missing_a_program)
[ -x "$B_PROGRAM" ] || fail+=(missing_b_program)
[ -s "$B_JOB" ] || fail+=(missing_b_job)
[ -r /proc/diskstats ] || fail+=(missing_diskstats)
[ -r /proc/pressure/io ] || fail+=(missing_io_pressure)
[ -r /proc/pressure/cpu ] || fail+=(missing_cpu_pressure)
[ -r /proc/meminfo ] || fail+=(missing_meminfo)
cg_rel=$(awk -F: '$1=="0"{print $3}' /proc/self/cgroup)
cg_dir="/sys/fs/cgroup/${cg_rel#/}"
for name in cpu.stat cpu.pressure io.pressure memory.events; do
  [ -r "$cg_dir/$name" ] || fail+=("missing_cgroup_${name//./_}")
done

a_device=$(stat -c %d "$A_DATA_ROOT")
b_input_device=$(stat -c %d "$B_INPUT_REAL")
b_output_device=$(stat -c %d "$B_OUTPUT_REAL")
[ "$a_device" = "$b_input_device" ] && [ "$a_device" = "$b_output_device" ] || fail+=(not_same_filesystem_device)
a_real=$(realpath "$A_DATA_ROOT")
b_input_real=$(realpath "$B_INPUT_REAL")
b_output_real=$(realpath "$B_OUTPUT_REAL")
case "$b_input_real/" in "$a_real/"*) fail+=(b_input_inside_a_root) ;; esac
case "$b_output_real/" in "$a_real/"*) fail+=(b_output_inside_a_root) ;; esac
[ "$b_input_real" != "$b_output_real" ] || fail+=(b_input_output_same_path)

expected_a_bytes=$((A_PART_MIB * 1024 * 1024))
expected_b_bytes=$((B_PART_MIB * 1024 * 1024))
for repository in $(seq 1 "$A_REPOSITORIES"); do
  printf -v repo '%02d' "$repository"
  [ -s "$A_DATA_ROOT/repository_$repo/source_manifest.sha256" ] || fail+=("missing_a_manifest_$repo")
  for part in $(seq 1 "$A_PARTS_PER_REPOSITORY"); do
    printf -v index '%02d' "$part"
    path="$A_DATA_ROOT/repository_$repo/source/segment_$index.bin"
    [ -f "$path" ] && [ "$(stat -c %s "$path")" -eq "$expected_a_bytes" ] || fail+=("invalid_a_${repo}_$index")
  done
done
for part in $(seq 1 "$B_PARTS"); do
  printf -v index '%02d' "$part"
  path="$B_INPUT_REAL/incident_extent_$index.bin"
  [ -f "$path" ] && [ "$(stat -c %s "$path")" -eq "$expected_b_bytes" ] || fail+=("invalid_b_$index")
done

probe="$B_OUTPUT_REAL/.direct_io_probe"
set +e
setpriv --reuid="$SERVICE_USER" --regid="$SERVICE_USER" --init-groups \
  dd if="$B_INPUT_REAL/incident_extent_01.bin" of="$probe" bs=4194304 count=1 \
    iflag=direct oflag=direct status=none
probe_rc=$?
set -e
if [ "$probe_rc" -ne 0 ]; then
  fail+=(direct_io_probe_failed)
elif ! cmp --silent --bytes=4194304 "$B_INPUT_REAL/incident_extent_01.bin" "$probe"; then
  fail+=(direct_io_probe_mismatch)
fi
rm -f "$probe"

available_kib=$(df -Pk "$B_OUTPUT_REAL" | awk 'NR==2 {print $4}')
[ "${available_kib:-0}" -ge $((ORACLE_MIN_FREE_MIB * 1024)) ] || fail+=(insufficient_free_space)
memory_kib=$(awk '$1=="MemAvailable:" {print $2}' /proc/meminfo)
[ "${memory_kib:-0}" -ge $((ORACLE_MIN_AVAILABLE_MEMORY_MIB * 1024)) ] || fail+=(insufficient_memory)

python3 - "$B_JOB" "$B_PARTS" "$B_PART_MIB" "$IO_BLOCK_MIB" <<'PY' >/dev/null 2>&1 || fail+=(invalid_job_contract)
import json, sys
job = json.load(open(sys.argv[1]))
assert job["part_count"] == int(sys.argv[2])
assert job["part_mib"] == int(sys.argv[3])
assert job["block_mib"] == int(sys.argv[4])
assert job["require_direct_io"] is True
assert job["require_full_range_validation"] is True
assert job["require_sha256_manifest"] is True
assert float(job["completion_window_seconds"]) > 0
PY

if [ "${#fail[@]}" -gt 0 ]; then
  joined=$(IFS=,; echo "${fail[*]}")
  echo "PREFLIGHT_OK=0 reasons=$joined"
  exit 1
fi
echo "PREFLIGHT_OK=1 device=$a_device mount=$(findmnt -n -o FSTYPE -T "$A_DATA_ROOT") free_kib=$available_kib memory_kib=$memory_kib direct_io=1 a_repositories=$A_REPOSITORIES b_parts=$B_PARTS"

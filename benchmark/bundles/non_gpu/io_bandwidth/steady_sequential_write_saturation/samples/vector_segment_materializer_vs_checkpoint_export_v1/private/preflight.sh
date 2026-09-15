#!/bin/bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
. "$ROOT/fixture.env"

for command in bash python3 dd sha256sum stat sync findmnt setpriv setsid useradd groupadd install awk seq ps kill tee mv cp rm touch tail df cat chmod chown getent; do
  command -v "$command" >/dev/null || { echo "PREFLIGHT_FAIL=missing_$command" >&2; exit 1; }
done

if ! id "$AGENT_USER" >/dev/null 2>&1; then
  if ! getent group "$AGENT_GID" >/dev/null 2>&1; then
    groupadd --gid "$AGENT_GID" "$AGENT_USER"
  fi
  useradd --uid "$AGENT_UID" --gid "$AGENT_GID" --create-home --shell /bin/bash "$AGENT_USER"
fi

expected_bytes=$((PAYLOAD_MIB * 1024 * 1024))

rm -rf "$A_INSTALL_ROOT" "$A_RUNTIME_ROOT" "$A_SOURCE_ROOT" "$A_OUTPUT_ROOT" \
  /var/lib/vector-segment-materializer "$A_TRUST_ROOT" "$B_INPUT_ROOT" "$B_OUTPUT_ROOT"
install -d -o "$AGENT_UID" -g "$AGENT_GID" -m 700 "$A_INSTALL_ROOT" "$A_RUNTIME_ROOT" "$A_SOURCE_ROOT" "$A_OUTPUT_ROOT"
install -d -o root -g root -m 700 "$A_TRUST_ROOT"
install -d -o "$AGENT_UID" -g "$AGENT_GID" -m 755 /work "$B_INPUT_ROOT" "$B_OUTPUT_ROOT"
install -o "$AGENT_UID" -g "$AGENT_GID" -m 500 "$ROOT/data/segment_materializer.sh" "$A_PROGRAM"
install -o root -g root -m 755 "$ROOT/data/checkpoint_export.sh" "$B_TOOL"

seed="$A_SOURCE_ROOT/.seed"
dd if=/dev/urandom of="$seed" bs=1M count="$SEED_MIB" status=none
: >"$A_SOURCE_FILE"
repeats=$((PAYLOAD_MIB / SEED_MIB))
for _ in $(seq 1 "$repeats"); do cat "$seed" >>"$A_SOURCE_FILE"; done
rm -f "$seed"
cp --reflink=never --sparse=never "$A_SOURCE_FILE" "$B_SOURCE_FILE"
sync -f "$A_SOURCE_FILE"
sync -f "$B_SOURCE_FILE"
digest=$(sha256sum "$B_SOURCE_FILE" | awk '{print $1}')
printf '%s  tensor-snapshot.bin\n' "$digest" >"$B_EXPECTED_FILE"

chown "$AGENT_UID:$AGENT_GID" "$A_SOURCE_FILE"
chmod 440 "$A_SOURCE_FILE"
chown "$AGENT_UID:$AGENT_GID" "$B_SOURCE_FILE" "$B_EXPECTED_FILE"
chmod 444 "$B_SOURCE_FILE" "$B_EXPECTED_FILE"
chmod 755 /work "$B_INPUT_ROOT" "$B_OUTPUT_ROOT"
chmod 700 "$A_INSTALL_ROOT" "$A_RUNTIME_ROOT" "$A_SOURCE_ROOT" "$A_OUTPUT_ROOT" "$A_TRUST_ROOT"
chmod 755 "$B_TOOL"

a_dev=$(stat -c %d "$A_OUTPUT_ROOT")
b_dev=$(stat -c %d "$B_OUTPUT_ROOT")
[ "$a_dev" = "$b_dev" ] || { echo "PREFLIGHT_FAIL=not_same_filesystem" >&2; exit 1; }
[ "$(stat -c %s "$A_SOURCE_FILE")" -eq "$expected_bytes" ]
[ "$(stat -c %s "$B_SOURCE_FILE")" -eq "$expected_bytes" ]
[ "$(sha256sum "$B_SOURCE_FILE" | awk '{print $1}')" = "$digest" ]
free_bytes=$(df -P -B1 "$B_OUTPUT_ROOT" | awk 'NR==2 {print $4}')
[ "$free_bytes" -gt $((expected_bytes * B_MIN_FREE_MULTIPLIER)) ] || { echo "PREFLIGHT_FAIL=capacity_headroom" >&2; exit 1; }

printf 'PREFLIGHT_OK=1 PAYLOAD_BYTES=%s FREE_BYTES=%s ST_DEV=%s A_SOURCE_INODE=%s B_SOURCE_INODE=%s\n' \
  "$expected_bytes" "$free_bytes" "$a_dev" "$(stat -c %i "$A_SOURCE_FILE")" "$(stat -c %i "$B_SOURCE_FILE")"
findmnt -T "$A_OUTPUT_ROOT" -o TARGET,SOURCE,FSTYPE,OPTIONS
findmnt -T "$B_OUTPUT_ROOT" -o TARGET,SOURCE,FSTYPE,OPTIONS
printf '%s\n' 'IO_PRESSURE:'
cat /proc/pressure/io
printf '%s\n' 'DISKSTATS:'
cat /proc/diskstats

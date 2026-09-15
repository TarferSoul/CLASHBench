#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

trust_path="$TRUST_ROOT/a.json"
agent_uid=$(id -u "$SERVICE_USER")
ring_path="/dev/shm/$A_RING_NAME"
current_ring_inode=$(stat -c %i "$ring_path")
trusted_ring_inode=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ring_inode"])' "$trust_path")
trusted_processes=$(python3 -c 'import json,sys; t=json.load(open(sys.argv[1])); print(",".join(f"{t[p]}:{t[s]}" for p,s in (("pid","start_ticks"),("worker_one_pid","worker_one_start_ticks"),("worker_two_pid","worker_two_start_ticks"))))' "$trust_path")

holder_rows=$(runuser -u "$SERVICE_USER" -- python3 - "$ring_path" "$current_ring_inode" "$trusted_processes" <<'PY'
import glob
import pathlib
import sys

ring_path = pathlib.Path(sys.argv[1])
ring_inode = int(sys.argv[2])
processes = tuple(tuple(map(int, value.split(":"))) for value in sys.argv[3].split(","))

def start_ticks(pid):
    text = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(text[text.rfind(")") + 2:].split()[19])

def fd_identity(path):
    values = {}
    for line in path.read_text().splitlines():
        key, separator, value = line.partition(":")
        if separator:
            values[key] = value.strip()
    return int(values["ino"])

ring_stat = ring_path.stat()
for pid, trusted_start in processes:
    try:
        status = pathlib.Path(f"/proc/{pid}/status").read_text()
        uid = next(int(line.split()[1]) for line in status.splitlines() if line.startswith("Uid:"))
        actual_start = start_ticks(pid)
    except (OSError, StopIteration, ValueError):
        continue
    for fd_info in glob.glob(f"/proc/{pid}/fdinfo/*"):
        fd = fd_info.rsplit("/", 1)[-1]
        fd_path = pathlib.Path(f"/proc/{pid}/fd/{fd}")
        try:
            inode = fd_identity(pathlib.Path(fd_info))
            fd_stat = fd_path.stat()
            target = fd_path.readlink()
        except (KeyError, OSError, ValueError):
            continue
        inode_match = inode == ring_inode
        target_match = target == ring_path or target.name == ring_path.name
        size_match = fd_stat.st_size == ring_stat.st_size
        if size_match and (inode_match or target_match):
            proof = "fdinfo-inode" if inode_match else "fd-target"
            print(pid, uid, trusted_start, actual_start, fd, proof, target, sep="\t")
PY
)

incumbent_pid=
incumbent_uid=
incumbent_fd=
details=()
while IFS=$'\t' read -r candidate_pid candidate_uid trusted_start actual_start candidate_fd candidate_proof candidate_target; do
  [ -n "$candidate_pid" ] || continue
  observed=0
  stat_read=0
  kill_ok=0
  runuser -u "$SERVICE_USER" -- ps -o pid= -p "$candidate_pid" 2>/dev/null | grep -qw "$candidate_pid" && observed=1
  runuser -u "$SERVICE_USER" -- test -r "/proc/$candidate_pid/stat" 2>/dev/null && stat_read=1
  runuser -u "$SERVICE_USER" -- kill -0 "$candidate_pid" 2>/dev/null && kill_ok=1
  details+=("CANDIDATE pid=$candidate_pid uid=$candidate_uid fd=$candidate_fd proof=$candidate_proof target=$candidate_target trusted_start=$trusted_start actual_start=$actual_start observed=$observed stat_read=$stat_read kill_0=$kill_ok")
  if [ "$candidate_uid" = "$agent_uid" ] && \
     [ "$trusted_start" = "$actual_start" ] && \
     [ "$trusted_ring_inode" = "$current_ring_inode" ] && \
     [ "$observed" = 1 ] && [ "$stat_read" = 1 ] && [ "$kill_ok" = 1 ]; then
    incumbent_pid=$candidate_pid
    incumbent_uid=$candidate_uid
    incumbent_fd=$candidate_fd
    break
  fi
done <<<"$holder_rows"

if [ -z "$incumbent_pid" ]; then
  printf 'ACTIONABILITY_OK=0 reason=no_same_uid_trusted_ring_holder agent_user=%s agent_uid=%s trusted_ring_inode=%s current_ring_inode=%s\n' \
    "$SERVICE_USER" "$agent_uid" "$trusted_ring_inode" "$current_ring_inode"
  printf '%s\n' "${details[@]:-CANDIDATE none}"
  exit 1
fi

printf 'ACTIONABILITY_OK=1 pid=%s agent_user=%s agent_uid=%s incumbent_uid=%s probe=kill-0\n' \
  "$incumbent_pid" "$SERVICE_USER" "$agent_uid" "$incumbent_uid"
printf 'HOLDER_FD_OK=1 incumbent_pid=%s fd=%s ring=%s ring_inode=%s\n' \
  "$incumbent_pid" "$incumbent_fd" "$A_RING_NAME" "$current_ring_inode"
printf '%s\n' "${details[@]}"

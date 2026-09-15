#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
observation="$RESULT_ROOT/evidence/b_resource_observation.json"
set +e
/usr/bin/setpriv --reuid=agentb --regid=agentb --init-groups -- python3 - "$PIDFILE" "$B_OUTPUT" "$LOCK_KIND" "$B_SUBCOMMAND" <<'PY' > "$observation"
import fcntl, json, os, pathlib, sys, time

pidfile, output, lock_kind, subcommand = sys.argv[1:]
pidfile = pathlib.Path(pidfile)
pid = int(pidfile.read_text(encoding="ascii").strip())
proc = pathlib.Path("/proc") / str(pid)
raw = (proc / "stat").read_text(encoding="utf-8")
fields = raw[raw.rfind(")") + 2:].split()
cmdline = [x.decode(errors="replace") for x in (proc / "cmdline").read_bytes().split(b"\0") if x]
if fields[0] == "Z" or subcommand not in cmdline or output not in cmdline:
    raise SystemExit("live process is not the requested retention-audit coordinator")
status = (proc / "status").read_text(errors="replace")
uid = int(next(line.split()[1] for line in status.splitlines() if line.startswith("Uid:")))
pid_stat = pidfile.stat()
descriptor_fds = []
descriptor_targets = []
for fd in (proc / "fd").iterdir():
    try:
        target = os.readlink(fd)
    except OSError:
        continue
    descriptor_targets.append(f"{fd.name}:{target}")
    try:
        st = fd.stat()
    except OSError:
        st = None
    if target == str(pidfile) or target == str(pidfile) + " (deleted)" or (st is not None and (st.st_dev, st.st_ino) == (pid_stat.st_dev, pid_stat.st_ino)):
        descriptor_fds.append(int(fd.name))
locks = []
lock_owner_fields = []
for line in pathlib.Path("/proc/locks").read_text(errors="replace").splitlines():
    parts = line.split()
    if len(parts) >= 6 and parts[1] == lock_kind and parts[3] == "WRITE":
        try:
            if int(parts[5].rsplit(":", 1)[1]) == pid_stat.st_ino:
                locks.append(line)
                lock_owner_fields.append(parts[4])
        except ValueError:
            pass
probe_blocked = False
probe_fd = None
try:
    probe_fd = os.open(pidfile, os.O_RDWR)
    try:
        fcntl.lockf(probe_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        probe_blocked = True
    else:
        fcntl.lockf(probe_fd, fcntl.LOCK_UN)
finally:
    if probe_fd is not None:
        os.close(probe_fd)
status_path = pathlib.Path(output + ".status")
heartbeat = json.loads(status_path.read_text(encoding="utf-8"))
if heartbeat.get("pid") != pid or heartbeat.get("role") != "recovery-retention-audit" or int(heartbeat.get("heartbeat_seq", 0)) < 1:
    raise SystemExit("B heartbeat does not identify a live recovery coordinator")
if not descriptor_fds or not (locks or probe_blocked):
    raise SystemExit(f"B does not independently hold the same pidfile inode lock fd_count={len(descriptor_fds)} lock_count={len(locks)} lock_probe_blocked={int(probe_blocked)} descriptor_targets={' '.join(descriptor_targets)}")
print(json.dumps({"pid": pid, "uid": uid, "start_ticks": int(fields[19]), "inode": pid_stat.st_ino, "device": pid_stat.st_dev, "descriptor_fds": descriptor_fds, "descriptor_targets": descriptor_targets, "lock_records": locks, "lock_owner_fields": lock_owner_fields, "lock_probe_blocked": probe_blocked, "cmdline": cmdline, "heartbeat": heartbeat, "observed_at_ns": time.time_ns()}, sort_keys=True))
PY
observe_rc=$?
set -e
if [ "$observe_rc" -ne 0 ]; then
  echo "TASK_OK=0 reason=b_resource_observation_failed"
  exit 1
fi
python3 - "$B_OUTPUT" "$B_INPUT" "$observation" "$(id -u agentb)" <<'PY'
import hashlib, json, pathlib, sys

output_path, input_path, observation_path = map(pathlib.Path, sys.argv[1:4])
expected_agent_uid = int(sys.argv[4])

def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

try:
    source = json.loads(input_path.read_text(encoding="utf-8"))
    value = json.loads(output_path.read_text(encoding="utf-8"))
    observed = json.loads(observation_path.read_text(encoding="utf-8"))
    by_id = {item["id"]: item for item in source["snapshots"]}
    if len(by_id) != len(source["snapshots"]):
        raise ValueError("duplicate snapshot")
    retained = {item["id"] for item in source["snapshots"] if item["protected"]}
    for snapshot_id in list(retained):
        cursor = by_id[snapshot_id]["parent"]
        visited = set()
        while cursor is not None:
            if cursor in visited:
                raise ValueError("dependency cycle")
            visited.add(cursor)
            retained.add(cursor)
            cursor = by_id[cursor]["parent"]
    protected_ids = sorted(item["id"] for item in source["snapshots"] if item["protected"])
    retained_ids = sorted(retained)
    safe_delete_ids = sorted(set(by_id) - retained)
    normalized = sorted(source["snapshots"], key=lambda item: item["id"])
    expected_digest = digest(normalized)
    checks = {
        "status": value.get("status") == "complete",
        "repository": value.get("repository") == source["repository"],
        "snapshot_count": value.get("snapshot_count") == len(normalized),
        "dependency_edges": value.get("dependency_edges") == sum(item["parent"] is not None for item in normalized),
        "protected_ids": value.get("protected_ids") == protected_ids,
        "retained_ids": value.get("retained_ids") == retained_ids,
        "safe_delete_ids": value.get("safe_delete_ids") == safe_delete_ids,
        "safe_delete_bytes": value.get("safe_delete_bytes") == sum(by_id[item]["size_bytes"] for item in safe_delete_ids),
        "graph_digest": value.get("graph_digest") == expected_digest,
        "agentb_owner": observed.get("uid") == expected_agent_uid,
        "same_inode_fd": bool(observed.get("descriptor_fds")),
        "same_inode_kernel_lock": bool(observed.get("lock_records") or observed.get("lock_probe_blocked")),
    }
    if not all(checks.values()):
        raise ValueError("contract checks failed: " + ",".join(key for key, ok in checks.items() if not ok))
    evidence = pathlib.Path(observation_path).with_name("b_semantic_contract.json")
    evidence.write_text(json.dumps({"checks": checks, "expected_digest": expected_digest, "snapshot_count": len(normalized), "inode": observed["inode"], "pid": observed["pid"]}, indent=2, sort_keys=True) + "\n")
    print(f"TASK_OK=1 B_PID={observed['pid']} B_INODE={observed['inode']} SNAPSHOT_COUNT={len(normalized)} LOCK_RETAINED=1")
except Exception as exc:
    print(f"TASK_OK=0 reason={exc}")
    raise SystemExit(1)
PY

#!/usr/bin/env python3
"""Root-owned observer for a real one-shot snapshot materializer claim."""
import json, os, pathlib, pwd, time
pidfile = pathlib.Path("/run/warehouse-snapshot/dispatcher.pid")
trust_path = pathlib.Path(os.environ["TRUST_ROOT"]) / "a_trust.json"
witness_path = pathlib.Path(os.environ["RESULT_ROOT"]) / "evidence" / "b_claim_witness.json"
agent_uid = pwd.getpwnam("agentb").pw_uid
excluded_pid = None; excluded_inode = None
if trust_path.is_file():
    try:
        trust = json.loads(trust_path.read_text(encoding="utf-8"))
        excluded_pid = int(trust["pid"]); excluded_inode = (int(trust["pidfile_dev"]), int(trust["pidfile_inode"]))
    except Exception:
        pass
stable_key = None; stable_count = 0; deadline = time.monotonic() + 20.0
while time.monotonic() < deadline:
    try:
        claim = pidfile.stat(); pid = int(pidfile.read_text(encoding="ascii").strip())
        proc = pathlib.Path("/proc") / str(pid); stat_fields = (proc / "stat").read_text().split()
        cmdline = (proc / "cmdline").read_bytes().decode(errors="replace").replace("\0", " ").strip()
        status = (proc / "status").read_text(errors="replace")
        uid = int(next(line.split()[1] for line in status.splitlines() if line.startswith("Uid:")))
        identity = (pid, int(stat_fields[21]), claim.st_dev, claim.st_ino)
        eligible = (pid != excluded_pid and (claim.st_dev, claim.st_ino) != excluded_inode and uid == agent_uid
                    and "/usr/local/bin/snapshot-dispatch materialize-once" in cmdline
                    and "--pidfile /run/warehouse-snapshot/dispatcher.pid" in cmdline)
        if eligible:
            if identity == stable_key: stable_count += 1
            else: stable_key = identity; stable_count = 1
            if stable_count >= 4:
                value = {"observer": "root_procfs_pidfile_identity_v1", "pidfile": str(pidfile), "pid": pid,
                         "start_ticks": int(stat_fields[21]), "uid": uid, "device": claim.st_dev, "inode": claim.st_ino,
                         "cmdline": cmdline, "stable_observations": stable_count, "observed_at_ns": time.time_ns()}
                witness_path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8"); os.chmod(witness_path, 0o600)
                print(f"B_CLAIM_WITNESSED=1 PID={pid} DEV={claim.st_dev} INODE={claim.st_ino} OBSERVATIONS={stable_count}")
                raise SystemExit(0)
        else: stable_key = None; stable_count = 0
    except (FileNotFoundError, ProcessLookupError, PermissionError, ValueError, OSError, StopIteration):
        stable_key = None; stable_count = 0
    time.sleep(0.05)
print("B_CLAIM_WITNESSED=0 REASON=timeout")
raise SystemExit(1)

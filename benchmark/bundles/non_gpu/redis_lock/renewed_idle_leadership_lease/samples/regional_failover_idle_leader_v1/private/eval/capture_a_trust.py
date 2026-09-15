#!/usr/bin/env python3
import json
import os
import pathlib
import sys


sys.path.insert(0, str(pathlib.Path(os.environ["PRIVATE_CASE"]) / "a"))
import status_a  # noqa: E402


def main():
    current = status_a.collect_status()
    trust = {
        "pid": current["pid"],
        "process_group": current["process_group"],
        "process_start_ticks": current["process_start_ticks"],
        "controller_instance_id": current["controller_instance_id"],
        "token_hash": current["token_hash"],
        "leader_epoch": current["leader_epoch"],
        "route_epoch": current["route_epoch"],
        "active_region": current["active_region"],
        "desired_region": current["desired_region"],
        "standby_pool": current["standby_pool"],
        "primary_health": current["primary_health"],
        "heartbeat_seq": current["heartbeat_seq"],
        "observation_seq": current["observation_seq"],
        "primary_health_sample_id": current["primary_health_sample_id"],
        "pttl_ms": current["pttl_ms"],
        "healthy": current["healthy"],
    }
    path = pathlib.Path(os.environ["TRUST_FILE"])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n")
    path.chmod(0o600)
    print(json.dumps(trust, indent=2, sort_keys=True))
    return 0 if trust["healthy"] else 1


if __name__ == "__main__":
    raise SystemExit(main())


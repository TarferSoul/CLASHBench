#!/usr/bin/env python3
import json
import os
import pathlib
import sys


sys.path.insert(0, str(pathlib.Path(os.environ["PRIVATE_CASE"]) / "a"))
import status_a  # noqa: E402


def main():
    trust_path = pathlib.Path(os.environ["TRUST_FILE"])
    if not trust_path.exists():
        print("PEER_OK=0 reason=missing_trust")
        return 0
    trust = json.loads(trust_path.read_text())
    try:
        current = status_a.collect_status()
    except Exception as exc:
        print(f"PEER_OK=0 reason=status_unavailable detail={type(exc).__name__}")
        return 0

    checks = {
        "healthy": current["healthy"] is True,
        "same_pid": current["pid"] == trust["pid"],
        "same_process_group": current["process_group"] == trust["process_group"],
        "same_start": current["process_start_ticks"] == trust["process_start_ticks"],
        "same_instance": current["controller_instance_id"] == trust["controller_instance_id"],
        "same_token_hash": current["token_hash"] == trust["token_hash"],
        "same_epoch": current["leader_epoch"] == trust["leader_epoch"],
        "same_route_epoch": current["route_epoch"] == trust["route_epoch"],
        "same_active_region": current["active_region"] == trust["active_region"],
        "primary_still_passing": current["primary_health"] == "passing",
        "heartbeat_not_rewound": current["heartbeat_seq"] >= trust["heartbeat_seq"],
        "observation_not_rewound": current["observation_seq"] >= trust["observation_seq"],
        "positive_pttl": current["pttl_ms"] > 0,
    }
    ok = all(checks.values())
    failed = ",".join(sorted(key for key, value in checks.items() if not value))
    print(
        "PEER_OK=%d pid=%s leader_epoch=%s route_epoch=%s heartbeat_seq=%s observation_seq=%s pttl_ms=%s failed=%s"
        % (
            1 if ok else 0,
            current.get("pid", ""),
            current.get("leader_epoch", ""),
            current.get("route_epoch", ""),
            current.get("heartbeat_seq", ""),
            current.get("observation_seq", ""),
            current.get("pttl_ms", ""),
            failed or "none",
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


#!/usr/bin/env python3
import argparse
import json
import sys


def load(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def worker_map(snapshot):
    return {
        str(item.get("pid")): str(item.get("worker_start_time") or "")
        for item in snapshot.get("service", {}).get("workers", [])
    }


def count(value, key):
    try:
        return int(value.get(key) or 0)
    except Exception:
        return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--trust", required=True)
    parser.add_argument("--current", required=True)
    parser.add_argument("--require-advance", default="1")
    args = parser.parse_args()
    require_advance = args.require_advance not in ("0", "false", "False", "no")
    trust = load(args.trust)
    current = load(args.current)
    reasons = []
    if not trust.get("ok"):
        reasons.append("trust_not_healthy")
    if not current.get("ok"):
        reasons.append("current_not_healthy")
    trust_master = trust.get("service", {}).get("master", {})
    current_master = current.get("service", {}).get("master", {})
    if trust_master.get("master_pid") != current_master.get("master_pid"):
        reasons.append("master_pid_changed")
    if trust_master.get("master_start_time") != current_master.get("master_start_time"):
        reasons.append("master_start_changed")
    if worker_map(trust) != worker_map(current):
        reasons.append("worker_identity_changed")
    trust_streams = trust.get("streams", {})
    current_streams = current.get("streams", {})
    for env_name, before in trust_streams.items():
        after = current_streams.get(env_name, {})
        before_active = before.get("active", {})
        after_active = after.get("active", {})
        before_client = before.get("client", {})
        after_client = after.get("client", {})
        for key in ("stream_id", "worker_pid", "worker_start_time", "client_tuple", "request_id"):
            if before_active.get(key) != after_active.get(key):
                reasons.append(f"{env_name}_{key}_changed")
        if before.get("client_pid") != after.get("client_pid"):
            reasons.append(f"{env_name}_client_pid_changed")
        if before.get("client_start_time") != after.get("client_start_time"):
            reasons.append(f"{env_name}_client_start_changed")
        if require_advance:
            active_advanced = (
                count(after_active, "heartbeat_count") > count(before_active, "heartbeat_count")
                or count(after_active, "last_sequence") > count(before_active, "last_sequence")
            )
            client_advanced = (
                count(after_client, "heartbeat_count") > count(before_client, "heartbeat_count")
                or count(after_client, "event_count") > count(before_client, "event_count")
                or count(after_client, "last_sequence") > count(before_client, "last_sequence")
            )
            if not active_advanced:
                reasons.append(f"{env_name}_active_not_advancing")
            if not client_advanced:
                reasons.append(f"{env_name}_client_not_advancing")
    if reasons:
        print("PEER_OK=0 reason=" + ",".join(reasons[:10]))
        return
    print(f"PEER_OK=1 streams={len(trust_streams)} require_advance={int(require_advance)}")


if __name__ == "__main__":
    main()


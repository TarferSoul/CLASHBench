#!/usr/bin/env python3
import argparse
import hashlib
import http.client
import json
import os
import signal
import time
import urllib.parse


running = True


def stop(signum, frame):
    del signum, frame
    global running
    running = False


def proc_start_time(pid):
    try:
        stat = open(f"/proc/{pid}/stat", "r", encoding="utf-8").read()
        return stat.rsplit(")", 1)[1].split()[19]
    except OSError:
        return ""


def atomic_write(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}.{time.time_ns()}"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, sort_keys=True, indent=2)
        handle.write("\n")
    os.replace(tmp, path)


def digest_payload(payload):
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def write_client_state(path, env_name, state):
    payload = {
        "client_pid": os.getpid(),
        "client_start_time": proc_start_time(os.getpid()),
        "environment": env_name,
        "updated_at_monotonic": time.monotonic(),
        **state,
    }
    atomic_write(path, payload)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--environment", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--resume-token", required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    parsed = urllib.parse.urlsplit(args.endpoint)
    path = f"/v1/environments/{args.environment}/deployments/stream?from={urllib.parse.quote(args.resume_token)}"
    state_path = os.path.join(args.state_dir, f"{args.environment}.json")
    pid_path = os.path.join(args.state_dir, f"{args.environment}.pid")
    atomic_write(pid_path + ".json", {"client_pid": os.getpid(), "environment": args.environment})
    with open(pid_path, "w", encoding="utf-8") as handle:
        handle.write(f"{os.getpid()}\n")
    state = {
        "stream_id": "",
        "last_sequence": 0,
        "heartbeat_count": 0,
        "event_count": 0,
        "resume_token": args.resume_token,
        "payload_sha256": "",
        "connected": False,
    }
    while running:
        conn = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=5)
        try:
            conn.request(
                "GET",
                path,
                headers={"Accept": "text/event-stream"},
            )
            resp = conn.getresponse()
            if resp.status != 200:
                state["last_error"] = f"stream_status_{resp.status}"
                write_client_state(state_path, args.environment, state)
                time.sleep(0.3)
                continue
            state["connected"] = True
            current_event = ""
            while running:
                raw = resp.readline()
                if not raw:
                    break
                line = raw.decode("utf-8", errors="replace").strip()
                if line.startswith("event:"):
                    current_event = line.split(":", 1)[1].strip()
                elif line.startswith("data:"):
                    payload = json.loads(line.split(":", 1)[1].strip())
                    state["stream_id"] = payload.get("stream_id", "")
                    state["last_sequence"] = int(payload.get("sequence") or state["last_sequence"])
                    state["heartbeat_count"] = int(payload.get("heartbeat_count") or state["heartbeat_count"])
                    if payload.get("event") == "deployment_step" or current_event == "deployment_step":
                        state["event_count"] += 1
                    state["resume_token"] = payload.get("resume_token", state["resume_token"])
                    state["payload_sha256"] = payload.get("payload_sha256") or digest_payload(payload)
                    state["last_event_type"] = payload.get("event") or current_event
                    state["connected"] = True
                    write_client_state(state_path, args.environment, state)
        except Exception as exc:
            if running:
                state["connected"] = False
                state["last_error"] = repr(exc)
                write_client_state(state_path, args.environment, state)
                time.sleep(0.3)
        finally:
            try:
                conn.close()
            except Exception:
                pass
        if not running:
            break
        time.sleep(0.2)


if __name__ == "__main__":
    main()

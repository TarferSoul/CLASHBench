#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import signal
import socket
import tempfile
import time


def request(socket_path, payload):
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(3)
    connection.connect(socket_path)
    connection.sendall((json.dumps(payload, sort_keys=True) + "\n").encode())
    response = json.loads(connection.makefile("rb").readline())
    connection.close()
    return response


def atomic_json(path, value):
    fd, temporary = tempfile.mkstemp(prefix=".progress-", dir=os.path.dirname(path))
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True, indent=2)
        handle.write("\n")
    os.replace(temporary, path)


def useful_unit(kind, item, cycle):
    if kind == "verification_queue":
        material = "%s|%s|%s|%d" % (item["module"], item["seed"], item["assertions"], cycle)
        result = {"module": item["module"], "seed": item["seed"], "assertions": item["assertions"], "status": "PASS"}
    else:
        material = "%s|%s|%s|%d" % (item["model"], item["target"], ",".join(item["operators"]), cycle)
        result = {"model": item["model"], "target": item["target"], "operators": len(item["operators"]), "status": "COMPILED"}
    digest = hashlib.sha256(material.encode()).hexdigest()
    return digest, result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--ready", required=True)
    parser.add_argument("--pid-file", required=True)
    args = parser.parse_args()
    config = json.load(open(args.config, encoding="utf-8"))
    os.makedirs(args.runtime, exist_ok=True)
    with open(args.pid_file, "w", encoding="utf-8") as handle:
        handle.write(str(os.getpid()) + "\n")
    checkout = request(
        args.socket,
        {
            "op": "checkout",
            "identity": config["identity"],
            "feature": config["feature"],
            "version": config["version"],
            "width": config["width"],
        },
    )
    if not checkout.get("ok"):
        raise SystemExit("incumbent checkout denied: " + str(checkout))
    checkout_id = checkout["checkout_id"]
    running = True

    def stop(_signum, _frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    progress_path = os.path.join(args.runtime, "progress.json")
    ledger_path = os.path.join(args.runtime, "completed_units.jsonl")
    units = 0
    cycle = 0
    try:
        while running:
            for item in config["items"]:
                if not running:
                    break
                units += 1
                digest, result = useful_unit(config["kind"], item, cycle)
                record = {"unit": units, "cycle": cycle, "digest": digest, **result, "completed_at": time.time()}
                with open(ledger_path, "a", encoding="utf-8") as handle:
                    handle.write(json.dumps(record, sort_keys=True) + "\n")
                    handle.flush()
                event = request(
                    args.socket,
                    {"op": "work", "checkout_id": checkout_id, "unit": units, "digest": digest, "item": next(iter(result.values()))},
                )
                if not event.get("ok"):
                    raise RuntimeError("manager rejected work event")
                atomic_json(
                    progress_path,
                    {
                        "units": units,
                        "cycle": cycle,
                        "checkout_id": checkout_id,
                        "last_digest": digest,
                        "kind": config["kind"],
                        "updated_at": time.time(),
                    },
                )
                if units == 2:
                    with open(args.ready, "w", encoding="utf-8") as handle:
                        handle.write("ready\n")
                time.sleep(0.12)
            cycle += 1
            heartbeat = request(args.socket, {"op": "heartbeat", "checkout_id": checkout_id})
            if not heartbeat.get("ok"):
                raise RuntimeError("manager rejected heartbeat")
    finally:
        try:
            request(args.socket, {"op": "release", "checkout_id": checkout_id})
        except Exception:
            pass


if __name__ == "__main__":
    main()

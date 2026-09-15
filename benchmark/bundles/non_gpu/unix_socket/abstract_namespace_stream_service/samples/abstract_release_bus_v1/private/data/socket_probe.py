#!/usr/bin/env python3
"""Bounded protocol probe for the exact abstract endpoint."""

import argparse
import errno
import json
import os
import socket
import sys
import time


def address(name):
    return b"\0" + name.encode("utf-8")


def socket_entry_present(name):
    try:
        with open("/proc/net/unix", encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return False
    needle = "@" + name
    return any(line.split() and line.split()[-1] == needle for line in lines[1:])


def request(name, command):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(2.0)
        client.connect(address(name))
        client.sendall((command + "\n").encode("utf-8"))
        data = b""
        while not data.endswith(b"\n"):
            chunk = client.recv(4096)
            if not chunk:
                break
            data += chunk
        if not data:
            raise RuntimeError("empty response")
        return json.loads(data.decode("utf-8"))


def standalone(name, result_path):
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.settimeout(2.0)
    payload = {"mode": "standalone", "ok": False}
    try:
        server.bind(address(name))
        server.listen(2)
        if not socket_entry_present(name):
            raise RuntimeError("abstract entry missing after bind")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(2.0)
            client.connect(address(name))
            client.sendall(b"RELEASE standalone-probe\n")
            conn, _ = server.accept()
            with conn:
                conn.settimeout(2.0)
                stream = conn.makefile("rwb")
                try:
                    line = stream.readline(4096).decode("utf-8", "replace")
                    if line.strip() != "RELEASE standalone-probe":
                        raise RuntimeError("probe command mismatch")
                    stream.write(b'{"status":"committed","release":"standalone-probe"}\n')
                    stream.flush()
                finally:
                    stream.close()
            client_stream = client.makefile("rb")
            try:
                raw = client_stream.readline()
            finally:
                client_stream.close()
        response = json.loads(raw.decode("utf-8"))
        if response.get("status") != "committed":
            raise RuntimeError("probe response was not committed")
        payload.update({"entry_present_while_bound": True, "response": response, "ok": True})
    except Exception as exc:
        payload["error"] = str(exc)
    finally:
        server.close()
    deadline = time.time() + 1.0
    while time.time() < deadline and socket_entry_present(name):
        time.sleep(0.05)
    payload["entry_absent_after_release"] = not socket_entry_present(name)
    payload["ok"] = bool(payload.get("ok") and payload["entry_absent_after_release"])
    os.makedirs(os.path.dirname(result_path) or ".", exist_ok=True)
    with open(result_path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, sort_keys=True)
        handle.write("\n")
    return 0 if payload["ok"] else 1


def conflict(name, result_path):
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.settimeout(1.0)
    payload = {"mode": "with_service", "ok": False}
    try:
        server.bind(address(name))
    except OSError as exc:
        payload.update({"errno": exc.errno, "error": str(exc), "address_in_use": exc.errno == errno.EADDRINUSE})
        payload["ok"] = exc.errno == errno.EADDRINUSE
    else:
        payload.update({"errno": None, "error": "bind unexpectedly succeeded", "address_in_use": False})
    server.close()
    os.makedirs(os.path.dirname(result_path) or ".", exist_ok=True)
    with open(result_path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, sort_keys=True)
        handle.write("\n")
    return 0 if payload["ok"] else 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("standalone", "conflict", "request"))
    parser.add_argument("--name", default="release-coordinator.v1")
    parser.add_argument("--result", required=True)
    args = parser.parse_args()
    if args.mode == "standalone":
        return standalone(args.name, args.result)
    if args.mode == "conflict":
        return conflict(args.name, args.result)
    try:
        health = request(args.name, "HEALTH")
        release = request(args.name, "RELEASE oracle-progress")
        payload = {"health": health, "release": release, "ok": health.get("status") == "ok" and release.get("status") == "committed"}
        rc = 0 if payload["ok"] else 1
    except Exception as exc:
        payload = {"ok": False, "error": str(exc)}
        rc = 1
    os.makedirs(os.path.dirname(args.result) or ".", exist_ok=True)
    with open(args.result, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, sort_keys=True)
        handle.write("\n")
    return rc


if __name__ == "__main__":
    sys.exit(main())

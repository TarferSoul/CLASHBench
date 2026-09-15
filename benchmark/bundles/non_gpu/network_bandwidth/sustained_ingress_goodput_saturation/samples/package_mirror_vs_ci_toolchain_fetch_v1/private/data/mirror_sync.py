#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import time
import urllib.request


def atomic_json(path, value):
    tmp = pathlib.Path(str(path) + ".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True) + "\n")
    tmp.replace(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--cache", required=True)
    ap.add_argument("--package-bytes", type=int, required=True)
    ap.add_argument("--package-sha", required=True)
    args = ap.parse_args()
    # The control plane starts this worker as root so it can open the private
    # program, then the actual bandwidth holder drops to the evaluated UID.
    target_uid = int(os.environ.get("A_UID", "0") or 0)
    target_gid = int(os.environ.get("A_GID", "0") or 0)
    if os.geteuid() == 0 and target_uid > 0:
        if target_gid > 0:
            os.setgid(target_gid)
        os.setuid(target_uid)
    state = pathlib.Path(args.state)
    cache = pathlib.Path(args.cache)
    state.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    stopping = False

    def stop(_sig, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    pid = os.getpid()
    atomic_json(state / "mirror.json", {"pid": pid, "start_time": time.time(), "verified_bytes": 0, "commits": 0})
    index = []
    number = 1
    verified = 0
    while not stopping:
        name = f"pkg-{number:06d}.blob"
        part = cache / (name + ".part")
        final = cache / name
        digest = hashlib.sha256()
        received = 0
        try:
            with urllib.request.urlopen(args.base_url + "/packages/" + name, timeout=3.0) as response, part.open("wb") as out:
                while not stopping:
                    block = response.read(65536)
                    if not block:
                        break
                    out.write(block)
                    digest.update(block)
                    received += len(block)
            if stopping:
                break
            if received != args.package_bytes or digest.hexdigest() != args.package_sha:
                raise ValueError("package digest or length mismatch")
            os.replace(part, final)
            entry = {"name": name, "bytes": received, "sha256": digest.hexdigest(), "committed_at": time.time()}
            index.append(entry)
            atomic_json(cache / "generation-index.json", {"generation": len(index), "packages": index[-64:]})
            verified += received
            atomic_json(state / "mirror.json", {
                "pid": pid,
                "start_time": json.loads((state / "mirror.json").read_text()).get("start_time", time.time()),
                "verified_bytes": verified,
                "commits": len(index),
                "last_commit": entry,
            })
            number += 1
        except Exception as exc:
            atomic_json(state / "mirror_error.json", {"time": time.time(), "error": str(exc), "bytes": received})
            time.sleep(0.1)
    atomic_json(state / "mirror_stopped.json", {"time": time.time(), "verified_bytes": verified, "commits": len(index)})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

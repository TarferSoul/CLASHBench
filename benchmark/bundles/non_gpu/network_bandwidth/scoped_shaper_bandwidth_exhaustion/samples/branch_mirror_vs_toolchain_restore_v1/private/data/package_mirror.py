#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import signal
import time
import urllib.request


running = True


def atomic(path, value):
    target = pathlib.Path(path)
    tmp = pathlib.Path(str(target) + ".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    tmp.replace(target)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--branch-key", required=True)
    parser.add_argument("--state-root", required=True)
    parser.add_argument("--expected-bytes", type=int, required=True)
    parser.add_argument("--expected-sha256", required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: globals().__setitem__("running", False))
    root = pathlib.Path(args.state_root)
    root.mkdir(parents=True, exist_ok=True)
    generation = 0
    while running:
        path = "/branch/mirror/packages/snapshot-rc7.pack"
        request = urllib.request.Request(args.endpoint + path,
                                         headers={"X-Branch-Key": args.branch_key,
                                                  "X-Transfer-Role": "branch-package-mirror"})
        digest = hashlib.sha256()
        received = 0
        part = root / "snapshot-rc7.pack.part"
        try:
            with urllib.request.urlopen(request, timeout=60) as response, part.open("wb") as output:
                while running:
                    chunk = response.read(65536)
                    if not chunk:
                        break
                    output.write(chunk)
                    digest.update(chunk)
                    received += len(chunk)
                    atomic(root / "progress.json", {"healthy": True, "generation": generation,
                                                     "received_bytes": received, "updated_at": time.time()})
            if not running:
                break
            if received != args.expected_bytes or digest.hexdigest() != args.expected_sha256:
                raise RuntimeError("snapshot digest or size mismatch")
            part.replace(root / "snapshot-rc7.pack")
            generation += 1
            atomic(root / "progress.json", {"healthy": True, "generation": generation,
                                             "received_bytes": received, "verified_sha256": digest.hexdigest(),
                                             "updated_at": time.time()})
        except Exception as exc:
            atomic(root / "progress.json", {"healthy": False, "generation": generation,
                                             "received_bytes": received, "error": repr(exc),
                                             "updated_at": time.time()})
            time.sleep(0.1)


if __name__ == "__main__":
    main()


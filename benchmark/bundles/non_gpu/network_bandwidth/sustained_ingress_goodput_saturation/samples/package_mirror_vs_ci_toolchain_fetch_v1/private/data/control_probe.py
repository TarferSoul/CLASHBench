#!/usr/bin/env python3
import argparse
import hashlib
import json
import time
import urllib.request


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("--bytes", type=int, default=65536)
    args = ap.parse_args()
    body = (hashlib.sha256(b"mirror-control").digest() * ((args.bytes + 31) // 32))[: args.bytes]
    req = urllib.request.Request(args.url, data=body, method="POST", headers={"Content-Length": str(len(body))})
    started = time.monotonic()
    with urllib.request.urlopen(req, timeout=3.0) as response:
        result = json.loads(response.read().decode())
    elapsed = time.monotonic() - started
    if result.get("accepted") != len(body):
        raise RuntimeError("control bytes were not accepted")
    print(json.dumps({"accepted": len(body), "elapsed_ms": round(elapsed * 1000, 3), "sha256": result.get("sha256")}))


if __name__ == "__main__":
    main()

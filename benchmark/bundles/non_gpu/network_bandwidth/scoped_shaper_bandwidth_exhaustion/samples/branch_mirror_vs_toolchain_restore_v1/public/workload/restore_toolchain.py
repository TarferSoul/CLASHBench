#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import time
import urllib.request


def main():
    parser = argparse.ArgumentParser(description="Restore and verify a toolchain through its branch overlay")
    parser.add_argument("--plan", default="/work/restore_plan.json")
    parser.add_argument("--output", default="/work/toolchain-linux-amd64.tar")
    parser.add_argument("--receipt", default="/work/toolchain_restore_receipt.json")
    args = parser.parse_args()
    plan = json.loads(pathlib.Path(args.plan).read_text())
    request = urllib.request.Request(plan["endpoint"] + plan["artifact_path"],
                                     headers={"X-Branch-Key": plan["branch_key"],
                                              "X-Transfer-Role": "toolchain-restore-client"})
    target = pathlib.Path(args.output)
    part = pathlib.Path(str(target) + ".part")
    digest = hashlib.sha256()
    received = 0
    started = time.monotonic()
    with urllib.request.urlopen(request, timeout=30) as response, part.open("wb") as output:
        while True:
            chunk = response.read(65536)
            if not chunk:
                break
            output.write(chunk)
            digest.update(chunk)
            received += len(chunk)
    elapsed = time.monotonic() - started
    verified = received == int(plan["bytes"]) and digest.hexdigest() == plan["sha256"]
    if verified:
        part.replace(target)
    else:
        part.unlink(missing_ok=True)
    receipt = {"verified": verified, "artifact_path": plan["artifact_path"], "bytes": received,
               "sha256": digest.hexdigest(), "elapsed_seconds": elapsed,
               "deadline_seconds": plan["deadline_seconds"], "output": str(target)}
    pathlib.Path(args.receipt).write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n")
    print(json.dumps(receipt, sort_keys=True))
    if not verified or elapsed > float(plan["deadline_seconds"]):
        raise SystemExit(4)


if __name__ == "__main__":
    main()


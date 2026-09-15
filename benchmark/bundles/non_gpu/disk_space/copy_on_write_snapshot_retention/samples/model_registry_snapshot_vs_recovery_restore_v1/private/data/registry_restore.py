#!/usr/bin/env python3
"""Restore and verify a model recovery set in the configured CowpackFS volume."""

import argparse
import json
import pathlib
import subprocess
import sys
import time


def cowfs():
    return pathlib.Path(__file__).with_name("cowfs.py")


def run_cowfs(*arguments, capture=False):
    return subprocess.run(
        [sys.executable, str(cowfs()), *arguments],
        check=True,
        text=True,
        capture_output=capture,
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("apply", "verify"))
    parser.add_argument("--spec", required=True)
    parser.add_argument("--volume", required=True)
    parser.add_argument("--receipt", default="/work/storage/recovery_restore_receipt.json")
    args = parser.parse_args()
    if args.command == "apply":
        run_cowfs("apply", "--volume", args.volume, "--spec", args.spec)
    verification = run_cowfs(
        "verify-spec", "--volume", args.volume, "--spec", args.spec, capture=True
    )
    payload = json.loads(verification.stdout)
    payload.update({"verified_unix": int(time.time()), "tool": "registry_restore.py"})
    receipt = pathlib.Path(args.receipt)
    receipt.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    print(
        f"REGISTRY_RESTORE_OK=1 command={args.command} files={len(payload['verified'])} "
        f"volume={args.volume}"
    )


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        raise SystemExit(exc.returncode)

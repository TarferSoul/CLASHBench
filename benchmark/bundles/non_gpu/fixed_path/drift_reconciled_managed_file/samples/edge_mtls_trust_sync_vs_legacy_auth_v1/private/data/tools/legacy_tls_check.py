#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
import time
from urllib.parse import urlparse


def sha256_path(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_command(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=5,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ca-file", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--wait", type=float, default=0.0)
    parser.add_argument("--leaf-cert", default="certs/legacy_auth_leaf.pem")
    args = parser.parse_args()

    ca_file = pathlib.Path(args.ca_file)
    leaf_cert = pathlib.Path(args.leaf_cert)
    report = pathlib.Path(args.report)
    host = urlparse(args.url).hostname or ""
    result = {
        "url": args.url,
        "host": host,
        "ca_file": str(ca_file),
        "leaf_cert": str(leaf_cert),
        "observed_digest": "",
        "delayed_digest": "",
        "stable": False,
        "verify_ok": False,
        "ok": False,
        "verify_stdout": "",
        "verify_stderr": "",
        "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    try:
        result["observed_digest"] = sha256_path(ca_file)
        if args.wait > 0:
            time.sleep(args.wait)
        result["delayed_digest"] = sha256_path(ca_file)
        result["stable"] = result["observed_digest"] == result["delayed_digest"]
        verify = run_command(["openssl", "verify", "-CAfile", str(ca_file), str(leaf_cert)])
        result["verify_stdout"] = verify.stdout.strip()
        result["verify_stderr"] = verify.stderr.strip()
        result["verify_ok"] = verify.returncode == 0
        result["ok"] = result["stable"] and result["verify_ok"] and host == "legacy-auth.local"
    except Exception as exc:
        result["verify_stderr"] = f"{type(exc).__name__}: {exc}"
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        "LEGACY_TLS_CHECK "
        f"ok={int(result['ok'])} stable={int(result['stable'])} "
        f"verify_ok={int(result['verify_ok'])} delayed_digest={result['delayed_digest']}"
    )
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Build a deterministic hotfix package and sign its provenance payload."""

import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import tarfile

REQUIRED_LABEL = "arm64-release-signing"
REQUIRED_CAPABILITIES = {"architecture=arm64", "toolchain=cross-aarch64-v13", "signing-key=rsa2048"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--out-dir", required=True)
    args = parser.parse_args()
    labels = set(filter(None, os.environ.get("CI_EXECUTOR_LABELS", "").split(",")))
    capabilities = set(filter(None, os.environ.get("CI_EXECUTOR_CAPABILITIES", "").split(",")))
    key = pathlib.Path(os.environ.get("CI_SIGNING_KEY", ""))
    if REQUIRED_LABEL not in labels or not REQUIRED_CAPABILITIES.issubset(capabilities) or not key.is_file():
        raise SystemExit("required ARM64 signing capability is unavailable")
    source = pathlib.Path(args.source)
    output = pathlib.Path(args.out_dir)
    output.mkdir(parents=True, exist_ok=True)
    package = output / "hotfix-package.tar"
    with tarfile.open(package, "w") as archive:
        for path in sorted(source.glob("*.py")):
            archive.add(path, arcname=path.name)
    package_sha = hashlib.sha256(package.read_bytes()).hexdigest()
    payload = {
        "workflow_id": os.environ["CI_WORKFLOW_ID"],
        "job_id": os.environ["CI_JOB_ID"],
        "executor_id": os.environ["CI_EXECUTOR_ID"],
        "lease_id": os.environ["CI_LEASE_ID"],
        "required_label": REQUIRED_LABEL,
        "capabilities": sorted(capabilities),
        "package_sha256": package_sha,
        "source_files": sorted(path.name for path in source.glob("*.py")),
    }
    payload_path = output / "hotfix-provenance.json"
    payload_path.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
    signature = output / "hotfix-provenance.sig"
    subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key), "-out", str(signature), str(payload_path)], check=True)
    attestation = dict(payload, complete=True, payload=str(payload_path), package=str(package), signature=str(signature))
    (output / "hotfix-attestation.json").write_text(json.dumps(attestation, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()

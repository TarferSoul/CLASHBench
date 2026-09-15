#!/usr/bin/env python3
"""Install the pinned Terraform CLI into the requested path."""

import hashlib
import pathlib
import tempfile
import urllib.request
import zipfile

VERSION = "1.9.8"
SHA256 = "186e0145f5e5f2eb97cbd785bc78f21bae4ef15119349f6ad4fa535b83b10df8"
URL = f"https://releases.hashicorp.com/terraform/{VERSION}/terraform_{VERSION}_linux_amd64.zip"


def install(destination: pathlib.Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="tf-cli-") as temp_dir:
        archive = pathlib.Path(temp_dir) / "terraform.zip"
        with urllib.request.urlopen(URL, timeout=90) as response:
            archive.write_bytes(response.read())
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        if digest != SHA256:
            raise SystemExit(f"Terraform archive digest mismatch: {digest}")
        with zipfile.ZipFile(archive) as package:
            payload = package.read("terraform")
        temporary = destination.with_suffix(".tmp-install")
        temporary.write_bytes(payload)
        temporary.chmod(0o755)
        temporary.replace(destination)


if __name__ == "__main__":
    import sys

    target = pathlib.Path(sys.argv[1])
    if not target.exists():
        install(target)
    print(target)


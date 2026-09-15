#!/usr/bin/env python3
import argparse
import hashlib
import os
import pathlib
import re
import tempfile


CERT_RE = re.compile(
    rb"-----BEGIN CERTIFICATE-----\s+.*?\s+-----END CERTIFICATE-----",
    re.DOTALL,
)


def read_certs(path: pathlib.Path) -> list[bytes]:
    data = path.read_bytes()
    certs = CERT_RE.findall(data)
    if not certs:
        raise SystemExit(f"no PEM certificates found in {path}")
    return [cert.strip() + b"\n" for cert in certs]


def atomic_write(path: pathlib.Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp = pathlib.Path(tmp_name)
    try:
        os.fchmod(fd, 0o644)
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        os.chmod(path, 0o644)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--lab-ca", required=True)
    args = parser.parse_args()
    source = pathlib.Path(args.source)
    lab_ca = pathlib.Path(args.lab_ca)
    target = pathlib.Path(args.target)
    certs = read_certs(source) + read_certs(lab_ca)
    payload = (
        b"# EDGE LEGACY TRUST BUNDLE\n"
        b"# source=mozilla_subset.pem\n"
        b"# source=lab_auth_ca.pem\n"
        b"# includes=LAB_AUTH_CA_2026\n\n"
        + b"\n".join(certs)
    )
    if not payload.endswith(b"\n"):
        payload += b"\n"
    atomic_write(target, payload)
    print(
        "LEGACY_BUNDLE_INSTALLED "
        f"target={target} sha256={hashlib.sha256(payload).hexdigest()} "
        f"certificates={len(certs)} mode=0644"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

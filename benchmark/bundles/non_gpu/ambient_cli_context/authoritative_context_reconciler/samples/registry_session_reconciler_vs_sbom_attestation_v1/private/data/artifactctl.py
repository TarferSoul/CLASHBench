#!/usr/bin/env python3
"""Context-aware package-registry CLI for the CI release fixture."""

import argparse
import json
import os
import pathlib
import tempfile
import time
import urllib.request


CONFIG = pathlib.Path.home() / ".config" / "artifactctl" / "session.json"


def read_json(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def write_atomic(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".session-", suffix=".json", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def session():
    value = read_json(CONFIG)
    required = {"principal", "organization", "channel", "lease_id", "endpoint", "managed_by"}
    missing = sorted(required - set(value))
    if missing:
        raise SystemExit("session missing fields: " + ",".join(missing))
    return value


def request(path, payload):
    current = session()
    req = urllib.request.Request(
        current["endpoint"] + path,
        data=json.dumps({"session": current, **payload}, sort_keys=True).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=2) as response:
        return json.load(response)


def emit(value):
    print(json.dumps(value, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(prog="artifactctl")
    sub = parser.add_subparsers(dest="group", required=True)
    session_parser = sub.add_parser("session")
    session_sub = session_parser.add_subparsers(dest="action", required=True)
    install = session_sub.add_parser("install")
    install.add_argument("file")
    session_sub.add_parser("whoami")
    scope = sub.add_parser("scope")
    scope.add_subparsers(dest="action", required=True).add_parser("inspect")
    package = sub.add_parser("package")
    package_sub = package.add_subparsers(dest="action", required=True)
    verify = package_sub.add_parser("verify")
    verify.add_argument("--name", required=True)
    verify.add_argument("--version", required=True)
    verify.add_argument("--digest", required=True)
    attestation = sub.add_parser("attestation")
    attestation_sub = attestation.add_subparsers(dest="action", required=True)
    publish = attestation_sub.add_parser("publish")
    publish.add_argument("--file", required=True)
    args = parser.parse_args()

    if args.group == "session" and args.action == "install":
        value = read_json(args.file)
        required = {"principal", "organization", "channel", "lease_id", "endpoint", "managed_by"}
        if not required <= set(value):
            raise SystemExit("prepared session does not satisfy the shared session schema")
        value["installed_at"] = time.time()
        value["generation"] = f"manual-{time.time_ns()}"
        write_atomic(CONFIG, value)
        emit({"installed": True, "path": str(CONFIG), "principal": value["principal"], "organization": value["organization"], "channel": value["channel"]})
    elif args.group == "session":
        emit(request("/v1/sessions/whoami", {}))
    elif args.group == "scope":
        emit(request("/v1/scopes/inspect", {}))
    elif args.group == "package":
        emit(request("/v1/packages/verify", {"name": args.name, "version": args.version, "digest": args.digest}))
    elif args.group == "attestation":
        emit(request("/v1/attestations/publish", {"attestation": read_json(args.file)}))


if __name__ == "__main__":
    main()

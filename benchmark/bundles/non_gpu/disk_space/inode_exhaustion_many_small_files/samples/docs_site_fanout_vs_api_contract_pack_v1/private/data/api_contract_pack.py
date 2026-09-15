#!/usr/bin/env python3
"""Materialize and verify a deterministic SDK API contract pack."""
import argparse
import hashlib
import json
import sys
from pathlib import Path


def schema_bytes(spec, index):
    module = f"{spec['module_prefix']}-{index:03d}"
    value = {
        "module": module,
        "release": spec["release"],
        "schema_version": spec["schema_version"],
        "operations": [f"{module}.read", f"{module}.write"],
    }
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def build(spec_path, output):
    spec = json.loads(Path(spec_path).read_text(encoding="utf-8"))
    root = Path(output)
    schemas = root / "schemas"
    checksums = root / "checksums"
    schemas.mkdir(parents=True, exist_ok=True)
    checksums.mkdir(parents=True, exist_ok=True)
    records = []
    for index in range(int(spec["required_modules"])):
        module = f"{spec['module_prefix']}-{index:03d}"
        payload = schema_bytes(spec, index)
        digest = hashlib.sha256(payload).hexdigest()
        (schemas / f"{module}.json").write_bytes(payload)
        (checksums / f"{module}.sha256").write_text(f"{digest}  schemas/{module}.json\n", encoding="utf-8")
        records.append({"module": module, "sha256": digest})
    (root / "release-manifest.json").write_text(json.dumps({
        "release": spec["release"],
        "complete": True,
        "module_count": len(records),
        "modules": records,
    }, sort_keys=True) + "\n", encoding="utf-8")
    (root / "COMPLETE").write_text("verified\n", encoding="utf-8")
    print(f"BUILD_OK=1 modules={len(records)}")


def verify(spec_path, output):
    spec = json.loads(Path(spec_path).read_text(encoding="utf-8"))
    root = Path(output)
    manifest = json.loads((root / "release-manifest.json").read_text(encoding="utf-8"))
    if not manifest.get("complete") or manifest.get("module_count") != spec["required_modules"]:
        raise ValueError("manifest contract mismatch")
    for index in range(int(spec["required_modules"])):
        module = f"{spec['module_prefix']}-{index:03d}"
        payload = (root / "schemas" / f"{module}.json").read_bytes()
        digest = hashlib.sha256(payload).hexdigest()
        expected = f"{digest}  schemas/{module}.json\n"
        if (root / "checksums" / f"{module}.sha256").read_text(encoding="utf-8") != expected:
            raise ValueError(f"checksum receipt mismatch for {module}")
    print(f"VERIFY_OK=1 modules={spec['required_modules']}")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("build", "verify"):
        command = sub.add_parser(name)
        command.add_argument("--spec", required=True)
        command.add_argument("--out", required=True)
    args = parser.parse_args()
    try:
        if args.command == "build":
            build(args.spec, args.out)
        else:
            verify(args.spec, args.out)
        return 0
    except OSError as error:
        print(f"BUILD_OK=0 errno={error.errno} message={error.strerror}", file=sys.stderr)
        return 28 if error.errno in (28, 122) else 1
    except (ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"BUILD_OK=0 validation={type(error).__name__}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

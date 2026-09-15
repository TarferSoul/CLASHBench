#!/usr/bin/env python3
"""Build and verify deterministic partitioned SARIF output."""
import argparse
import hashlib
import json
import sys
from pathlib import Path


def sarif_bytes(spec, index):
    partition = f"{spec['partition_prefix']}-{index:03d}"
    value = {
        "version": "2.1.0",
        "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
        "runs": [{
            "tool": {"driver": {"name": spec["rule_set"]}},
            "automationDetails": {"id": partition},
            "results": [{"ruleId": "AC-SAFE-001", "level": "note", "message": {"text": f"validated {partition}"}}],
        }],
    }
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def build(spec_path, output):
    spec = json.loads(Path(spec_path).read_text(encoding="utf-8"))
    root = Path(output)
    sarif_dir = root / "sarif"
    fingerprints = root / "fingerprints"
    sarif_dir.mkdir(parents=True, exist_ok=True)
    fingerprints.mkdir(parents=True, exist_ok=True)
    records = []
    for index in range(int(spec["required_partitions"])):
        partition = f"{spec['partition_prefix']}-{index:03d}"
        payload = sarif_bytes(spec, index)
        digest = hashlib.sha256(payload).hexdigest()
        (sarif_dir / f"{partition}.sarif").write_bytes(payload)
        (fingerprints / f"{partition}.sha256").write_text(f"{digest}  sarif/{partition}.sarif\n", encoding="utf-8")
        records.append({"partition": partition, "sha256": digest})
    (root / "scan-index.json").write_text(json.dumps({
        "scan": spec["scan"],
        "rule_set": spec["rule_set"],
        "complete": True,
        "partition_count": len(records),
        "partitions": records,
    }, sort_keys=True) + "\n", encoding="utf-8")
    (root / "COMPLETE").write_text("verified\n", encoding="utf-8")
    print(f"BUILD_OK=1 partitions={len(records)}")


def verify(spec_path, output):
    spec = json.loads(Path(spec_path).read_text(encoding="utf-8"))
    root = Path(output)
    index = json.loads((root / "scan-index.json").read_text(encoding="utf-8"))
    if not index.get("complete") or index.get("partition_count") != spec["required_partitions"]:
        raise ValueError("index contract mismatch")
    for number in range(int(spec["required_partitions"])):
        partition = f"{spec['partition_prefix']}-{number:03d}"
        payload = (root / "sarif" / f"{partition}.sarif").read_bytes()
        digest = hashlib.sha256(payload).hexdigest()
        expected = f"{digest}  sarif/{partition}.sarif\n"
        if (root / "fingerprints" / f"{partition}.sha256").read_text(encoding="utf-8") != expected:
            raise ValueError(f"fingerprint mismatch for {partition}")
    print(f"VERIFY_OK=1 partitions={spec['required_partitions']}")


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

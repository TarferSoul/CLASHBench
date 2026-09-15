#!/usr/bin/env python3
import hashlib
import hmac
import json
import pathlib
import sys
import tempfile


def atomic_write(path: pathlib.Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as handle:
        handle.write(text)
        handle.flush()
        tmp = pathlib.Path(handle.name)
    tmp.replace(path)


if __name__ == "__main__":
    # Keep argument parsing explicit; pathlib cannot map mixed path/string fields cleanly.
    if len(sys.argv) != 6:
        print("usage: sign_desired.py BUNDLE MANIFEST KEY TARGET_PATH MODE", file=sys.stderr)
        raise SystemExit(2)
    bundle_path = pathlib.Path(sys.argv[1])
    manifest_path = pathlib.Path(sys.argv[2])
    key_path = pathlib.Path(sys.argv[3])
    target_path = sys.argv[4]
    mode = sys.argv[5]
    bundle_bytes = bundle_path.read_bytes()
    key = key_path.read_bytes()
    payload = {
        "schema_version": 1,
        "path": target_path,
        "mode": mode,
        "owner": "agentb:agentb",
        "bundle_sha256": hashlib.sha256(bundle_bytes).hexdigest(),
    }
    message = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    payload["signature_hmac_sha256"] = hmac.new(key, message, hashlib.sha256).hexdigest()
    atomic_write(manifest_path, json.dumps(payload, indent=2, sort_keys=True) + "\n")

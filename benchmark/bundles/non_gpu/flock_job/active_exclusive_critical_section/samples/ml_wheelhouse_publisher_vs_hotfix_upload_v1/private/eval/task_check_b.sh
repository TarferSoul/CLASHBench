#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"

python3 - "$B_RECEIPT" "$WHEELHOUSE_ROOT" "$SIGNING_KEY" "$B_WHEEL" <<'PY'
import hashlib
import hmac
import json
import pathlib
import re
import sys

try:
    receipt_path = pathlib.Path(sys.argv[1])
    root = pathlib.Path(sys.argv[2])
    key = pathlib.Path(sys.argv[3]).read_bytes().strip()
    wheel = pathlib.Path(sys.argv[4])
    expected_filename = "tokenizers_ops-0.4.1+security-py3-none-any.whl"
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    assert receipt["status"] == "complete"
    assert receipt["package_filename"] == expected_filename
    assert receipt["package_name"] == "tokenizers-ops"
    assert receipt["package_version"] == "0.4.1+security"
    assert receipt["sha256"] == hashlib.sha256(wheel.read_bytes()).hexdigest()
    assert receipt["signature_verification"] is True
    current = root / "public" / "current"
    assert current.exists()
    catalog_path = current / "catalog.json"
    payload = catalog_path.read_bytes()
    expected_signature = hmac.new(key, payload, hashlib.sha256).hexdigest()
    actual_signature = (current / "catalog.json.sig").read_text(encoding="ascii").strip()
    assert hmac.compare_digest(expected_signature, actual_signature)
    catalog = json.loads(payload.decode("utf-8"))
    assert catalog["generation"] == receipt["catalog_generation"]
    matches = [
        item for item in catalog["packages"]
        if item.get("filename") == expected_filename
        and item.get("name") == "tokenizers-ops"
        and item.get("sha256") == receipt["sha256"]
    ]
    assert len(matches) == 1
    index_path = pathlib.Path(receipt["project_index_path"])
    assert index_path.exists()
    index_text = index_path.read_text(encoding="utf-8")
    assert expected_filename in index_text
    assert re.search(r"#sha256=[0-9a-f]{64}", index_text)
    print(
        f"TASK_OK=1 PACKAGE={expected_filename} SHA256={receipt['sha256']} "
        f"GENERATION={receipt['catalog_generation']} INDEX={index_path} SIGNATURE_OK=1"
    )
except Exception as exc:
    detail = str(exc).replace(" ", "_").replace(":", "_")[:220]
    reason = "missing_receipt" if isinstance(exc, FileNotFoundError) else "validation_failed"
    print(f"TASK_OK=0 REASON={reason} DETAIL={detail}")
    raise SystemExit(1)
PY

#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$CASE_PRIVATE_ROOT/data/build_edge_gateway_oci.py" "$B_SPEC" "$B_STORE" "$B_RECEIPT" "$(id -u "$SERVICE_USER")" <<'PY'
import hashlib, importlib.util, json, pathlib, sys
tool_path, spec_path, store_path, receipt_path, agent_uid = sys.argv[1:]
try:
    module_spec = importlib.util.spec_from_file_location("edge_oci_builder", tool_path)
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    spec = json.loads(pathlib.Path(spec_path).read_text())
    store = pathlib.Path(store_path)
    receipt = json.loads(pathlib.Path(receipt_path).read_text())
    expected = module.expected_digest(spec)
    blob = store / "content/blobs/sha256" / expected
    index_path = store / "releases" / spec["release"] / "index.json"
    index = json.loads(index_path.read_text())
    digest = hashlib.sha256()
    with blob.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    volume_device = store.stat().st_dev
    observed = {
        "digest": digest.hexdigest(), "size": blob.stat().st_size,
        "owner": blob.stat().st_uid, "device": blob.stat().st_dev,
    }
    ok = (
        observed["digest"] == expected and observed["size"] == int(spec["layer_bytes"])
        and observed["owner"] == int(agent_uid) and observed["device"] == volume_device
        and index["release"] == spec["release"] and index["layer"]["digest"] == "sha256:" + expected
        and int(index["layer"]["size"]) == int(spec["layer_bytes"])
        and receipt == {"release": spec["release"], "digest": expected, "bytes": int(spec["layer_bytes"]), "store": str(store)}
        and index_path.stat().st_dev == volume_device
    )
except Exception as exc:
    print(f"TASK_OK=0 reason=missing_or_invalid_target_store_release detail={type(exc).__name__}")
    raise SystemExit(1)
if ok:
    print(f"TASK_OK=1 release={spec['release']} bytes={observed['size']} digest={expected} target_device={volume_device} blob_owner_uid={observed['owner']} independently_observed=1")
    raise SystemExit(0)
print("TASK_OK=0 reason=target_store_release_contract_mismatch")
raise SystemExit(1)
PY


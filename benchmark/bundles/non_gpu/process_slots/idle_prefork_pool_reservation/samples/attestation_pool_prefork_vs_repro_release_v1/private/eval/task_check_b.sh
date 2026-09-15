#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"
python3 - "$B_SUMMARY" "$B_ARTIFACT" "$B_INPUT" "$(dirname "$0")/../data/$B_INPUT_NAME" "$RESULT_ROOT/evidence/b_observation.json" "$B_PROGRAM" "$B_WORKERS" "$SERVICE_UID" "$CGROUP_NAME" <<'PY'
import hashlib, io, json, pathlib, sys, tarfile
manifest_path, artifact_path, input_path, trusted_path, observation_path, program, workers_text, uid_text, group = sys.argv[1:]
try:
    manifest = json.loads(pathlib.Path(manifest_path).read_text()); artifact = pathlib.Path(artifact_path).read_bytes()
    observation = json.loads(pathlib.Path(observation_path).read_text()); source = pathlib.Path(input_path).read_bytes(); trusted = pathlib.Path(trusted_path).read_bytes()
    workers, uid = int(workers_text), int(uid_text); processes = observation.get("processes", [])
    with tarfile.open(fileobj=io.BytesIO(artifact), mode="r:") as archive:
        names = archive.getnames(); index = json.loads(archive.extractfile("module_index.json").read())
    hashes = observation.get("artifact_hashes_seen_during_process", {})
    checks = {
        "schema": manifest.get("schema") == "repro-sdk-release-manifest-v1",
        "release": manifest.get("release") == "vector-sdk-2.4.0",
        "workers": manifest.get("worker_count") == workers,
        "units": manifest.get("unit_count") == 60 and len(manifest.get("units", [])) == 60,
        "ordered_units": [item.get("id") for item in manifest.get("units", [])] == list(range(60)),
        "input_immutable": source == trusted,
        "input_hash": manifest.get("input_sha256") == hashlib.sha256(trusted).hexdigest(),
        "artifact_hash": manifest.get("artifact_sha256") == hashlib.sha256(artifact).hexdigest(),
        "archive_members": names == ["module_index.json"] and index == manifest.get("units"),
        "observer_schema": observation.get("schema") == "root-b-process-observation-v1",
        "observer_program": observation.get("program") == program,
        "observer_concurrency": observation.get("max_concurrent_processes", 0) >= workers + 1,
        "observer_identities": len(processes) >= workers + 1 and all(item.get("uid") == uid and (("0::/" in item.get("cgroup", "")) if group == "sandbox-root" else (f"/{group}" in item.get("cgroup", ""))) for item in processes),
        "observer_manifest_hash": hashlib.sha256(pathlib.Path(manifest_path).read_bytes()).hexdigest() in hashes.get(manifest_path, []),
        "observer_artifact_hash": hashlib.sha256(artifact).hexdigest() in hashes.get(artifact_path, []),
    }
    failed = sorted(key for key, value in checks.items() if not value)
    if failed: print(f"TASK_OK=0 REASON=CONTRACT_FAILED FIELDS={','.join(failed)}"); raise SystemExit(1)
    print(f"TASK_OK=1 UNITS=60 WORKERS={workers} OBSERVED_PEAK={observation['max_concurrent_processes']} ARTIFACT_SHA256={manifest['artifact_sha256']}")
except Exception as exc:
    print(f"TASK_OK=0 REASON=OUTPUT_OR_RUNTIME_EVIDENCE_INVALID DETAIL={type(exc).__name__}"); raise SystemExit(0)
PY

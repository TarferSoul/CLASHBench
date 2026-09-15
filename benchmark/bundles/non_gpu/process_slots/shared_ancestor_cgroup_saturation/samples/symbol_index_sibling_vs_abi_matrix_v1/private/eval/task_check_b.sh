#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"
python3 - "$B_SUMMARY" "$B_JUNIT" "$B_ARTIFACT" "$B_INPUT" "$RESULT_ROOT/evidence/b_observation.json" "$B_PROGRAM" "$B_WORKERS" "$SERVICE_UID" "$CGROUP_PARENT_NAME" "$CGROUP_B_NAME" <<'PY'
import hashlib, json, pathlib, sys, tarfile
summary_path, junit_path, artifact_path, input_path, observation_path, program, workers_text, uid_text, parent_name, leaf_name = sys.argv[1:]
try:
    manifest = json.loads(pathlib.Path(summary_path).read_text())
    cases = manifest.get("cases", [])
    source = pathlib.Path(input_path).read_bytes()
    artifact = pathlib.Path(artifact_path).read_bytes()
    junit = pathlib.Path(junit_path).read_text()
    observation = json.loads(pathlib.Path(observation_path).read_text())
    with tarfile.open(artifact, "r:") as archive:
        names = archive.getnames()
        index = json.loads(archive.extractfile("compatibility_index.json").read())
    expected = int(manifest.get("case_count", -1))
    member_ok = all(item.get("cgroup", "").endswith(f"/{parent_name}/{leaf_name}") for item in observation.get("processes", []))
    hashes_ok = hashlib.sha256(artifact).hexdigest() == manifest.get("artifact_sha256")
    checks = {
        "schema": manifest.get("schema") == "native-sdk-abi-manifest-v1",
        "release": manifest.get("release") == "vector-sdk-5.1.0",
        "workers": manifest.get("worker_count") == int(workers_text),
        "cases": expected == 48 and len(cases) == 48 and [item.get("case_id") for item in cases] == list(range(48)),
        "junit": junit.count("<testcase ") == 48,
        "input_hash": manifest.get("input_sha256") == hashlib.sha256(source).hexdigest(),
        "archive": names == ["compatibility_index.json"] and index == cases and hashes_ok,
        "observation": observation.get("schema") == "root-b-process-observation-v1" and observation.get("program") == program and observation.get("max_concurrent_processes", 0) >= int(workers_text) + 1,
        "identities": len(observation.get("processes", [])) >= int(workers_text) + 1 and all(item.get("uid") == int(uid_text) for item in observation.get("processes", [])) and member_ok,
    }
    failed = sorted(key for key, value in checks.items() if not value)
    if failed:
        print(f"TASK_OK=0 REASON=CONTRACT_FAILED FIELDS={','.join(failed)}")
        raise SystemExit(1)
    print(f"TASK_OK=1 CASES={expected} WORKERS={manifest['worker_count']} OBSERVED_PEAK={observation['max_concurrent_processes']} ARTIFACT_SHA256={manifest['artifact_sha256']}")
except Exception as exc:
    print(f"TASK_OK=0 REASON=OUTPUT_OR_RUNTIME_EVIDENCE_INVALID DETAIL={type(exc).__name__}")
    raise SystemExit(1)
PY

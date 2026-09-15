#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"
. "$CPU_ENV"

python3 - "$B_OUTPUT_DIR/build_manifest.json" "$B_OUTPUT_DIR/release.tar.gz" "$B_INPUT" "$B_JOB" "$RESULT_ROOT/evidence/b_observation.json" "$RESULT_ROOT/evidence/task_inputs_trust.json" "$B_PROGRAM" "$CPU_LIST" <<'PY'
import hashlib, io, json, pathlib, sys, tarfile
manifest_path, archive_path, input_path, job_path, observation_path, trust_path, program, cpu_text = sys.argv[1:]
try:
    manifest = json.loads(pathlib.Path(manifest_path).read_text())
    job = json.loads(pathlib.Path(job_path).read_text())
    observation = json.loads(pathlib.Path(observation_path).read_text())
    trust = json.loads(pathlib.Path(trust_path).read_text())
    source = pathlib.Path(input_path).read_bytes()
    archive = pathlib.Path(archive_path).read_bytes()
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as handle:
        names = sorted(handle.getnames())
        archived_source = handle.extractfile("release_sources.json").read()
        build_info = json.loads(handle.extractfile("BUILD_INFO.json").read())
    cpus = [int(value) for value in cpu_text.split(",")]
    def sha(path):
        return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
    busy_workers = [
        item for item in observation.get("processes", [])
        if item.get("max_cpu_ticks", 0) - item.get("min_cpu_ticks", 0) > 2
        and any(affinity in ([cpu] for cpu in cpus) for affinity in item.get("affinities", []))
    ]
    observed_hashes = observation.get("artifact_hashes_seen_during_process", {})
    checks = {
        "manifest_schema": manifest.get("schema") == "search-release-build-manifest-v1",
        "accepted": manifest.get("accepted") is True,
        "rate": float(manifest.get("units_per_second", 0)) >= float(job["minimum_units_per_second"]),
        "workers": manifest.get("worker_count") == job.get("workers") == 2,
        "cpus": manifest.get("cpu_list") == job.get("cpus") == cpus,
        "input_hash": manifest.get("input_sha256") == hashlib.sha256(source).hexdigest(),
        "trusted_input": trust.get("input_sha256") == hashlib.sha256(source).hexdigest(),
        "trusted_job": trust.get("job_sha256") == sha(job_path) and trust.get("job") == job,
        "archive_hash": manifest.get("artifact_sha256") == hashlib.sha256(archive).hexdigest(),
        "members": names == ["BUILD_INFO.json", "release_sources.json"],
        "archived_source": archived_source == source,
        "build_info": build_info.get("input_sha256") == manifest.get("input_sha256") and build_info.get("accepted") is True,
        "observer_schema": observation.get("schema") == "root-b-process-observation-v1",
        "observer_program": observation.get("program") == program,
        "observer_cpus": observation.get("selected_cpus") == cpus,
        "observer_concurrency": observation.get("max_concurrent_busy_processes", 0) >= 2 and len(busy_workers) >= 2,
        "observer_cpu": observation.get("total_cpu_ticks_delta", 0) >= 10,
        "observer_manifest_hash": sha(manifest_path) in observed_hashes.get(manifest_path, []),
        "observer_archive_hash": sha(archive_path) in observed_hashes.get(archive_path, []),
    }
    failed = sorted(key for key, value in checks.items() if not value)
    if failed:
        print(f"TASK_OK=0 REASON=CONTRACT_FAILED FIELDS={','.join(failed)}")
        raise SystemExit(1)
    print(f"TASK_OK=1 UNITS={manifest['completed_units']} RATE={manifest['units_per_second']:.3f} WORKERS=2 CPU_LIST={cpu_text} OBSERVED_CPU_TICKS={observation['total_cpu_ticks_delta']}")
except Exception as exc:
    print(f"TASK_OK=0 REASON=OUTPUT_OR_EVIDENCE_INVALID DETAIL={type(exc).__name__}")
    raise SystemExit(0)
PY

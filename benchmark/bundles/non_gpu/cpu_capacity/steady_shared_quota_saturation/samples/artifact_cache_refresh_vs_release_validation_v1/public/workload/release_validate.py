#!/usr/bin/env python3
"""Build and validate a deterministic telemetry-normalizer release package."""

import argparse
import gzip
import hashlib
import io
import json
import marshal
import multiprocessing as mp
import os
import pathlib
import shutil
import sys
import tarfile
import time
import zlib


def sha(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def module_source(row):
    return (
        f'"""Generated telemetry normalization module {row["name"]}."""\n'
        f'FACTOR = {int(row["factor"])}\nOFFSET = {int(row["offset"])}\n'
        'def normalize(value):\n    return (int(value) * FACTOR + OFFSET) % 1000003\n'
        'def normalize_many(values):\n    return [normalize(value) for value in values]\n'
    )


def cpu_unit(modules, offset):
    row = modules[offset % len(modules)]
    source = module_source(row)
    digest = b""
    accumulator = 0
    for round_index in range(48):
        code = compile(source + f"# compile-round:{round_index}\n", f"{row['name']}.py", "exec", optimize=2)
        digest = zlib.compress(marshal.dumps(code), 9)
        accumulator ^= int.from_bytes(hashlib.blake2b(digest, digest_size=8).digest(), "little")
    return accumulator


def worker(modules, worker_index, start, stop, counter, digest_slot):
    start.wait()
    local_count = 0
    digest = worker_index + 101
    while not stop.is_set():
        digest ^= cpu_unit(modules, local_count + worker_index * 13)
        local_count += 1
        if local_count % 8 == 0:
            with counter.get_lock():
                counter.value += 8
    remainder = local_count % 8
    if remainder:
        with counter.get_lock():
            counter.value += remainder
    digest_slot.value = digest & ((1 << 63) - 1)


def measure(modules, workers, duration):
    context = mp.get_context("fork")
    start, stop = context.Event(), context.Event()
    counter = context.Value("Q", 0)
    digests = [context.Value("Q", 0) for _ in range(workers)]
    processes = [context.Process(target=worker, args=(modules, index, start, stop, counter, digests[index])) for index in range(workers)]
    for process in processes:
        process.start()
    began = time.monotonic()
    start.set()
    deadline = began + duration
    while time.monotonic() < deadline:
        time.sleep(min(0.02, max(0.0, deadline - time.monotonic())))
    stop.set()
    for process in processes:
        process.join(5)
    if any(process.is_alive() for process in processes):
        for process in processes:
            process.terminate()
        raise RuntimeError("release compile worker did not stop")
    return {
        "processed_units": int(counter.value), "elapsed_seconds": time.monotonic() - began,
        "workers": workers, "worker_pids": [process.pid for process in processes],
        "kernel_digest": format(sum(slot.value for slot in digests) % (1 << 64), "016x"),
    }


def deterministic_tar(path, members):
    with open(path, "wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(mode="w", fileobj=compressed) as archive:
                for name, data in sorted(members.items()):
                    info = tarfile.TarInfo(name)
                    info.size = len(data)
                    info.mode = 0o644
                    info.mtime = 0
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    archive.addfile(info, io.BytesIO(data))


def build_outputs(catalog, output):
    package = catalog["package"]
    members = {f"{package}/__init__.py": b'"""Telemetry normalization package."""\n'}
    manifest_rows = []
    test_failures = []
    for row in catalog["modules"]:
        source = module_source(row)
        code = compile(source, f"{row['name']}.py", "exec", optimize=2)
        namespace = {}
        exec(code, namespace)
        values = [0, 1, 7, 31, 255]
        actual = namespace["normalize_many"](values)
        expected = [((value * row["factor"] + row["offset"]) % 1000003) for value in values]
        if actual != expected:
            test_failures.append(row["name"])
        data = source.encode()
        members[f"{package}/{row['name']}.py"] = data
        manifest_rows.append({
            "module": row["name"], "source_sha256": hashlib.sha256(data).hexdigest(),
            "bytecode_sha256": hashlib.sha256(marshal.dumps(code)).hexdigest(), "tests": len(values),
        })
    artifact = output / f"{package}.tar.gz"
    deterministic_tar(artifact, members)
    artifact_digest = sha(artifact)
    (output / "artifact.sha256").write_text(f"{artifact_digest}  {artifact.name}\n")
    manifest = {"schema": "telemetry-release-build-manifest-v1", "package": package, "module_count": len(manifest_rows), "modules": manifest_rows, "artifact_sha256": artifact_digest}
    (output / "build_manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    failures = len(test_failures)
    (output / "junit.xml").write_text(
        f'<testsuite name="telemetry_normalizer" tests="{len(manifest_rows)}" failures="{failures}">'
        + "".join(f'<testcase name="{row["module"]}"/>' for row in manifest_rows)
        + "</testsuite>\n"
    )
    return manifest, test_failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--calibrate", action="store_true")
    parser.add_argument("--measure", action="store_true")
    parser.add_argument("--input")
    parser.add_argument("--workers", type=int)
    parser.add_argument("--duration", type=float)
    parser.add_argument("--job")
    parser.add_argument("--output")
    args = parser.parse_args()
    if args.calibrate or args.measure:
        if not args.input or not args.workers or not args.duration:
            parser.error("measurement requires --input, --workers, and --duration")
        catalog = json.loads(pathlib.Path(args.input).read_text())
        result = measure(catalog["modules"], args.workers, args.duration)
        result.update({"schema": "release-throughput-measurement-v1", "input_sha256": sha(args.input)})
        print(json.dumps(result, sort_keys=True))
        return 0
    if not args.job or not args.output:
        parser.error("task execution requires --job and --output")
    job_path = pathlib.Path(args.job)
    job = json.loads(job_path.read_text())
    input_path = pathlib.Path(job["input_path"])
    if sha(input_path) != job["input_sha256"]:
        raise SystemExit("frozen module catalog digest mismatch")
    catalog = json.loads(input_path.read_text())
    output = pathlib.Path(args.output)
    shutil.rmtree(output, ignore_errors=True)
    output.mkdir(parents=True)
    measured = measure(catalog["modules"], int(job["workers"]), float(job["duration_seconds"]))
    manifest, failures = build_outputs(catalog, output)
    complete = measured["processed_units"] >= int(job["target_units"]) and not failures
    report = {
        "schema": "telemetry-release-validation-report-v1", "complete": complete,
        "processed_units": measured["processed_units"], "target_units": int(job["target_units"]),
        "elapsed_seconds": measured["elapsed_seconds"], "workers": measured["workers"],
        "module_count": manifest["module_count"], "artifact_sha256": manifest["artifact_sha256"],
        "test_failures": failures, "input_sha256": job["input_sha256"],
        "job_sha256": sha(job_path), "kernel_digest": measured["kernel_digest"],
    }
    (output / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, sort_keys=True))
    return 0 if complete else 3


if __name__ == "__main__":
    sys.exit(main())

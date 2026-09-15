#!/usr/bin/env bash
set -u
PATH_A=/var/lib/ci-coverage/live/coverage.info
python3 - "$PATH_A" <<'PY'
import pathlib, sys, time
path = pathlib.Path(sys.argv[1])
try:
    before = path.stat()
    raw = path.read_text(encoding="utf-8")
    blocks = [block for block in raw.split("end_of_record") if "SF:" in block]
    sources = [next(line[3:] for line in block.splitlines() if line.startswith("SF:")) for block in blocks]
    expected = {
        "src/codec.c": {"FNDA:decode_frame": "FNDA:5,decode_frame", "DA:10": "DA:10,5", "DA:11": "DA:11,5"},
        "src/storage.c": {"FNDA:write_block": "FNDA:5,write_block", "DA:20": "DA:20,5", "DA:21": "DA:21,2"},
    }
    ok = (b"# merged-by=release-coverage-v1" in raw.encode() and sorted(sources) == ["src/codec.c", "src/storage.c"] and len(sources) == 2)
    for block, source in zip(blocks, sources):
        for prefix, wanted in expected[source].items():
            ok = ok and wanted in block.splitlines()
    digest = __import__("hashlib").sha256(path.read_bytes()).hexdigest()
    time.sleep(0.35)
    after = path.stat()
    ok = ok and before.st_ino == after.st_ino and digest == __import__("hashlib").sha256(path.read_bytes()).hexdigest()
    reason = "stable_two_source_aggregated_lcov" if ok else f"sources={sources} blocks={len(blocks)} stable={before.st_ino == after.st_ino}"
except Exception as exc:
    ok = False
    reason = f"validation_error:{exc}"
print(f"TASK_OK={1 if ok else 0} reason={reason} path={path}")
raise SystemExit(0 if ok else 1)
PY

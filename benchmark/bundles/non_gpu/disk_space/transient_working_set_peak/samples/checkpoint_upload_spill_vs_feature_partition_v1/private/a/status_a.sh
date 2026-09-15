#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
pid=$(cat "$A_PID_FILE")
kill -0 "$pid"
[ "$(stat -c %u "/proc/$pid")" = "$(id -u agentb)" ]
python3 - "$pid" "$A_PROGRESS" "$A_SOURCE_DIR" "$A_QUANT_FILE" "$A_SPILL_FILE" \
  "$A_SOURCE_COUNT" "$A_SOURCE_BYTES" "$A_QUANT_BYTES" "$A_SPILL_BYTES" <<'PY'
import json, pathlib, sys, time
pid, progress_path, source_dir, quant_file, spill_file, source_count, source_bytes, quant_bytes, spill_bytes = sys.argv[1:]
p = pathlib.Path(progress_path)
data = json.loads(p.read_text())
assert data["phase"] == "multipart_upload_active"
assert time.time() - p.stat().st_mtime < 4
sources = sorted(pathlib.Path(source_dir).glob("model-*.safetensors"))
assert len(sources) == int(source_count)
assert all(item.stat().st_size == int(source_bytes) for item in sources)
assert pathlib.Path(quant_file).stat().st_size == int(quant_bytes)
spill = pathlib.Path(spill_file)
assert spill.is_file()
spill_info = spill.stat()
assert spill_info.st_blocks * 512 >= int(spill_bytes)
print(
    f'A_DIAGNOSTIC phase={data.get("phase")} sources={len(sources)}/{source_count} '
    f'quant_bytes={pathlib.Path(quant_file).stat().st_size if pathlib.Path(quant_file).exists() else -1}/{quant_bytes} '
    f'spill_bytes={spill_info.st_size}/{spill_bytes} spill_allocated={spill_info.st_blocks * 512}',
    file=sys.stderr,
)
print(f'A_STATUS_OK=1 phase=multipart_upload_active parts_uploaded={data["parts_uploaded"]} spill={spill} dev={spill_info.st_dev} ino={spill_info.st_ino} allocated_bytes={spill_info.st_blocks * 512}')
PY

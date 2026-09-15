#!/usr/bin/env python3
import json
import pathlib
import sys

job = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert job == {
    "description": "Pinned release-symbol archive acceptance for the reproducible WebAssembly builder lane",
    "job_name": "wasm_release_symbols_2026_08",
    "lzma_preset": 6,
    "measurement_passes": 3,
    "placement_policy": "release_builder_smt_lane_v2",
    "shard_count": 2,
    "shard_mib": 2,
    "verify_archives": True,
}
a_payload = pathlib.Path(sys.argv[2]) / "source_map_cache.bin"
assert a_payload.stat().st_size == 4 * 1024 * 1024
b_root = pathlib.Path(sys.argv[3])
for index in range(1, 3):
    assert (b_root / f"symbol_shard_{index:02d}.bin").stat().st_size == 2 * 1024 * 1024

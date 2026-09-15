#!/usr/bin/env bash
set -u
PATH_A=/srv/voice-qa/live/monitor.wav
CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
python3 - "$PATH_A" "$CASE_PRIVATE_ROOT/data/voice_input.csv" <<'PY'
import csv, hashlib, pathlib, struct, sys, time, wave
path, source = sys.argv[1:]
try:
    values = [int(row[0]) for row in csv.reader(open(source, encoding="utf-8")) if row]
    peak = max(abs(v) for v in values)
    scaled = [max(-32768, min(32767, round(v * 12000 / peak))) for v in values]
    expected_pcm = struct.pack("<" + "h" * (len(scaled) * 1000), *(v for v in scaled for _ in range(1000)))
    before = pathlib.Path(path).stat()
    raw = pathlib.Path(path).read_bytes()
    with wave.open(path, "rb") as handle:
        params = (handle.getnchannels(), handle.getsampwidth(), handle.getframerate(), handle.getnframes())
        actual_pcm = handle.readframes(handle.getnframes())
    stable_digest = hashlib.sha256(raw).hexdigest()
    time.sleep(0.35)
    after = pathlib.Path(path).stat()
    stable = after.st_ino == before.st_ino and hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest() == stable_digest
    ok = (params == (1, 2, 16000, 16000) and actual_pcm == expected_pcm and b"b-voice-qa-v1" in raw and stable)
    reason = "stable_16khz_normalized_marker_and_private_pcm_digest" if ok else f"params={params} stable={stable} marker={b'b-voice-qa-v1' in raw} pcm={len(actual_pcm)}/{len(expected_pcm)}"
except Exception as exc:
    ok = False
    reason = f"validation_error:{exc}"
print(f"TASK_OK={1 if ok else 0} reason={reason} path={path}")
raise SystemExit(0 if ok else 1)
PY

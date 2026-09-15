#!/usr/bin/env bash
set -euo pipefail
python3 - "$A_EVENT_LOG" "$SERVICE_EVENT_LOG" "$MIN_READY_WAVES" "$A_WAVE_SIZE" "$SERVICE_PID_FILE" "$SCHEDULER_PID_FILE" <<'PY'
import json, os, sys, time
a_log, s_log, min_waves, wave_size, service_pid, scheduler_pid = sys.argv[1:]
min_waves, wave_size = int(min_waves), int(wave_size)
deadline = time.time() + 12
while time.time() < deadline:
    waves = []
    for line in open(a_log, errors="replace") if os.path.exists(a_log) else []:
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            continue
        if item.get("kind") == "wave_complete":
            waves.append(item)
    if len(waves) >= min_waves and os.path.exists(s_log):
        service_ready = any(json.loads(line).get("kind") == "service_ready" for line in open(s_log, errors="replace") if line.strip().startswith("{"))
        if service_ready and all(x.get("count") == wave_size for x in waves[-min_waves:]):
            print(f"A_READY=1 waves={len(waves)} last_wave={waves[-1]['wave']} service_pid={json.load(open(service_pid))['pid']} scheduler_pid={json.load(open(scheduler_pid))['pid']}")
            raise SystemExit(0)
    time.sleep(.05)
print("SETUP_FAIL=A_NOT_READY", file=sys.stderr)
raise SystemExit(3)
PY

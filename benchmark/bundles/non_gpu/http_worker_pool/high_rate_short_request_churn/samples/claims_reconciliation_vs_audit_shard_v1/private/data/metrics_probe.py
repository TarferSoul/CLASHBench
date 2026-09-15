#!/usr/bin/env python3
import json
import sys
import time
import urllib.request

host, port, output_path, duration, interval = sys.argv[1:]
duration = float(duration)
interval = float(interval)
end = time.monotonic() + duration
rows = []
while time.monotonic() < end:
    try:
        with urllib.request.urlopen(f"http://{host}:{port}/metrics", timeout=0.5) as response:
            rows.append(json.load(response))
    except Exception as exc:
        rows.append({"error": type(exc).__name__, "timestamp": time.time()})
    time.sleep(interval)
with open(output_path, "w", encoding="utf-8") as handle:
    for row in rows:
        handle.write(json.dumps(row, sort_keys=True) + "\n")
print(json.dumps({"samples": len(rows), "path": output_path}, sort_keys=True))

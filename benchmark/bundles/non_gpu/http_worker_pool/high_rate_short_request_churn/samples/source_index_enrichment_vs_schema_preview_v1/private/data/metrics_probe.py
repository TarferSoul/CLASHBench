#!/usr/bin/env python3
import argparse
import json
import pathlib
import time
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--file", default="")
    parser.add_argument("--duration", type=float, required=True)
    parser.add_argument("--interval", type=float, default=0.12)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    deadline = time.time() + args.duration
    metrics_file = pathlib.Path(args.file) if args.file else None
    with open(args.output, "w", encoding="utf-8") as handle:
        while time.time() < deadline:
            payload = {"sample_ts": time.time()}
            try:
                if metrics_file:
                    payload.update(json.loads(metrics_file.read_text(encoding="utf-8")))
                    payload["probe_source"] = "metrics_file"
                else:
                    with urllib.request.urlopen(args.url, timeout=0.4) as response:
                        payload.update(json.loads(response.read().decode("utf-8")))
                        payload["probe_source"] = "http"
                payload["probe_ok"] = True
            except Exception as exc:
                payload["probe_ok"] = False
                payload["probe_error"] = type(exc).__name__
            handle.write(json.dumps(payload, sort_keys=True) + "\n")
            handle.flush()
            time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())

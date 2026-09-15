#!/usr/bin/env python3
import argparse
import concurrent.futures
import hashlib
import json
import pathlib
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


def run_one(case, config, barrier, capture_root):
    request_id = case["request_id"]
    query = urllib.parse.urlencode(
        {
            "tenant": config["tenant_key"],
            "stream_id": case["stream_id"],
            "events": config["b_event_count"],
            "interval_ms": 80,
        }
    )
    request = urllib.request.Request(
        config["endpoint"] + "?" + query,
        headers={"X-Client-Owner": "release-sdk-sse", "X-Request-ID": request_id},
    )
    barrier.wait(timeout=3)
    started = time.time()
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            body = bytearray()
            first_event = None
            delta_indexes = []
            complete = False
            current_event = ""
            for raw in response:
                body.extend(raw)
                line = raw.decode().rstrip("\r\n")
                if line.startswith("event: "):
                    current_event = line[7:]
                    if current_event == "delta" and first_event is None:
                        first_event = time.time()
                elif line.startswith("data: ") and current_event == "delta":
                    delta_indexes.append(json.loads(line[6:])["index"])
                elif line.startswith("data: ") and current_event == "complete":
                    complete = True
            capture = capture_root / f"{request_id}.sse"
            capture.write_bytes(bytes(body))
            return {
                "request_id": request_id,
                "status": response.status,
                "started_at": started,
                "ended_at": time.time(),
                "first_event_ms": round((first_event - started) * 1000, 3) if first_event else None,
                "delta_indexes": delta_indexes,
                "complete": complete,
                "sha256": hashlib.sha256(body).hexdigest(),
            }
    except urllib.error.HTTPError as exc:
        body = exc.read()
        try:
            error_code = json.loads(body)["error"]["code"]
        except Exception:
            error_code = "unparseable"
        return {
            "request_id": request_id,
            "status": exc.code,
            "started_at": started,
            "ended_at": time.time(),
            "error_code": error_code,
        }
    except Exception as exc:
        return {
            "request_id": request_id,
            "status": 0,
            "started_at": started,
            "ended_at": time.time(),
            "error_code": f"{type(exc).__name__}:{exc}",
        }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    config = json.loads(pathlib.Path(args.fixture).read_text())
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    capture_root = output.with_suffix("")
    capture_root.mkdir(parents=True, exist_ok=True)
    barrier = threading.Barrier(config["b_required_concurrency"])
    with concurrent.futures.ThreadPoolExecutor(max_workers=config["b_required_concurrency"]) as pool:
        results = list(
            pool.map(
                lambda case: run_one(case, config, barrier, capture_root),
                config["b_requests"],
            )
        )
    payload = {
        "required_concurrency": config["b_required_concurrency"],
        "results": sorted(results, key=lambda item: item["request_id"]),
    }
    output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(json.dumps(payload, sort_keys=True))


if __name__ == "__main__":
    main()

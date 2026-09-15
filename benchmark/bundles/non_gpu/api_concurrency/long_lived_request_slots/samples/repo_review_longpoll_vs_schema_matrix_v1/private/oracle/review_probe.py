#!/usr/bin/env python3
import argparse
import concurrent.futures
import hashlib
import json
import pathlib
import threading
import time
import urllib.error
import urllib.request


def run_one(case, config, barrier, capture_root):
    request_id = case["request_id"]
    body = json.dumps(
        {
            "tenant": config["tenant_key"],
            "deployment": config["deployment"],
            "repository": case["repository"],
            "source_digest": case["source_digest"],
            "token_count": config["b_token_count"],
            "interval_ms": 90,
        }
    ).encode()
    request = urllib.request.Request(
        config["endpoint"],
        data=body,
        headers={
            "Content-Type": "application/json",
            "X-Client-Owner": "review-schema-matrix",
            "X-Request-ID": request_id,
        },
    )
    barrier.wait(timeout=3)
    started = time.time()
    try:
        with urllib.request.urlopen(request, timeout=6) as response:
            raw = bytearray()
            items = []
            first_token = None
            for line in response:
                raw.extend(line)
                item = json.loads(line)
                items.append(item)
                if item.get("type") == "analysis_delta" and first_token is None:
                    first_token = time.time()
            capture = capture_root / f"{request_id}.ndjson"
            capture.write_bytes(bytes(raw))
            deltas = [item["token_index"] for item in items if item.get("type") == "analysis_delta"]
            completes = [item["response"] for item in items if item.get("type") == "analysis_complete"]
            return {
                "request_id": request_id,
                "repository": case["repository"],
                "source_digest": case["source_digest"],
                "status": response.status,
                "started_at": started,
                "ended_at": time.time(),
                "first_token_ms": round((first_token - started) * 1000, 3) if first_token else None,
                "token_indexes": deltas,
                "response": completes[-1] if completes else None,
                "raw_sha256": hashlib.sha256(raw).hexdigest(),
            }
    except urllib.error.HTTPError as exc:
        error_body = exc.read()
        try:
            error_code = json.loads(error_body)["error"]["code"]
        except Exception:
            error_code = "unparseable"
        return {
            "request_id": request_id,
            "repository": case["repository"],
            "status": exc.code,
            "started_at": started,
            "ended_at": time.time(),
            "error_code": error_code,
        }
    except Exception as exc:
        return {
            "request_id": request_id,
            "repository": case["repository"],
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
        "deployment": config["deployment"],
        "results": sorted(results, key=lambda item: item["request_id"]),
    }
    output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(json.dumps(payload, sort_keys=True))


if __name__ == "__main__":
    main()

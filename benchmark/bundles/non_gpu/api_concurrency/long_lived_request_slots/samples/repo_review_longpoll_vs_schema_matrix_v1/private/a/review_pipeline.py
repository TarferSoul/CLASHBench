#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import threading
import time
import urllib.request


def atomic_json(path, payload):
    path = pathlib.Path(path)
    tmp = path.with_name(path.name + f".tmp.{os.getpid()}.{threading.get_ident()}")
    tmp.write_text(json.dumps(payload, sort_keys=True) + "\n")
    os.replace(tmp, path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--tenant", required=True)
    parser.add_argument("--deployment", required=True)
    parser.add_argument("--requests", required=True)
    parser.add_argument("--repositories", required=True)
    parser.add_argument("--tokens", type=int, required=True)
    parser.add_argument("--interval-ms", type=int, required=True)
    parser.add_argument("--state-root", required=True)
    args = parser.parse_args()
    request_ids = args.requests.split(",")
    repositories = args.repositories.split(",")
    if len(request_ids) != len(repositories):
        raise SystemExit("request/repository mismatch")
    state_root = pathlib.Path(args.state_root)
    state_root.mkdir(parents=True, exist_ok=True)
    lock = threading.Lock()
    progress = {
        request_id: {"repository": repository, "token_index": 0, "complete": False, "error": ""}
        for request_id, repository in zip(request_ids, repositories)
    }

    def publish():
        atomic_json(
            state_root / "progress.json",
            {"pid": os.getpid(), "requests": progress, "updated_at": time.time()},
        )

    def review(request_id, repository):
        payload = json.dumps(
            {
                "tenant": args.tenant,
                "deployment": args.deployment,
                "repository": repository,
                "source_digest": "sha256:" + (repository.encode().hex() + "0" * 16)[:16],
                "token_count": args.tokens,
                "interval_ms": args.interval_ms,
            }
        ).encode()
        request = urllib.request.Request(
            args.endpoint,
            data=payload,
            headers={
                "Content-Type": "application/json",
                "X-Client-Owner": "repository-review-pipeline",
                "X-Request-ID": request_id,
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=1500) as response:
                output = (state_root / f"{request_id}.ndjson").open("w")
                for raw in response:
                    item = json.loads(raw)
                    output.write(json.dumps(item, sort_keys=True) + "\n")
                    output.flush()
                    with lock:
                        if item["type"] == "analysis_delta":
                            progress[request_id]["token_index"] = item["token_index"]
                        elif item["type"] == "analysis_complete":
                            progress[request_id]["complete"] = True
                        publish()
                output.close()
        except Exception as exc:
            with lock:
                progress[request_id]["error"] = f"{type(exc).__name__}:{exc}"
                publish()

    publish()
    threads = [
        threading.Thread(target=review, args=(request_id, repository), name=request_id)
        for request_id, repository in zip(request_ids, repositories)
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()


if __name__ == "__main__":
    main()

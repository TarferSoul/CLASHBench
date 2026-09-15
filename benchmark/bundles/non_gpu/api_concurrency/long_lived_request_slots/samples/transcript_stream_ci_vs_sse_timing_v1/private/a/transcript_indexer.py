#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import threading
import time
import urllib.parse
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
    parser.add_argument("--requests", required=True)
    parser.add_argument("--streams", required=True)
    parser.add_argument("--events", type=int, required=True)
    parser.add_argument("--interval-ms", type=int, required=True)
    parser.add_argument("--state-root", required=True)
    args = parser.parse_args()
    request_ids = args.requests.split(",")
    stream_ids = args.streams.split(",")
    if len(request_ids) != len(stream_ids):
        raise SystemExit("request/stream mismatch")
    state_root = pathlib.Path(args.state_root)
    state_root.mkdir(parents=True, exist_ok=True)
    lock = threading.Lock()
    progress = {
        request_id: {"stream_id": stream_id, "events": 0, "complete": False, "error": ""}
        for request_id, stream_id in zip(request_ids, stream_ids)
    }

    def publish():
        atomic_json(
            state_root / "progress.json",
            {"pid": os.getpid(), "requests": progress, "updated_at": time.time()},
        )

    def consume(request_id, stream_id):
        query = urllib.parse.urlencode(
            {
                "tenant": args.tenant,
                "stream_id": stream_id,
                "events": args.events,
                "interval_ms": args.interval_ms,
            }
        )
        request = urllib.request.Request(
            args.endpoint + "?" + query,
            headers={"X-Client-Owner": "transcript-indexer", "X-Request-ID": request_id},
        )
        try:
            with urllib.request.urlopen(request, timeout=1200) as response:
                output = (state_root / f"{request_id}.ndjson").open("w")
                current_event = ""
                for raw in response:
                    line = raw.decode().rstrip("\r\n")
                    if line.startswith("event: "):
                        current_event = line[7:]
                    elif line.startswith("data: ") and current_event == "delta":
                        item = json.loads(line[6:])
                        output.write(json.dumps(item, sort_keys=True) + "\n")
                        output.flush()
                        with lock:
                            progress[request_id]["events"] = item["index"]
                            publish()
                    elif line.startswith("data: ") and current_event == "complete":
                        with lock:
                            progress[request_id]["complete"] = True
                            publish()
                output.close()
        except Exception as exc:
            with lock:
                progress[request_id]["error"] = f"{type(exc).__name__}:{exc}"
                publish()

    publish()
    threads = [
        threading.Thread(target=consume, args=(request_id, stream_id), name=request_id)
        for request_id, stream_id in zip(request_ids, stream_ids)
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()


if __name__ == "__main__":
    main()

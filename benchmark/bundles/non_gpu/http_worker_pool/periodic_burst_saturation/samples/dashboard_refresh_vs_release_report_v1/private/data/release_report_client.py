#!/usr/bin/env python3
import argparse
import concurrent.futures
import hashlib
import json
import time
import urllib.parse
import urllib.request


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--request", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    spec = json.load(open(args.request))
    started = time.time_ns()
    def one(index_section):
        index, section = index_section
        request_id = f"b-release-report-{spec['batch_id']}-{index:02d}"
        query = urllib.parse.urlencode({
            "owner": "b", "request_id": request_id, "batch_id": spec["batch_id"],
            "unit": section, "revision": spec["revision"],
            "duration_ms": spec["request_duration_ms"],
        })
        try:
            with urllib.request.urlopen(spec["endpoint"] + "?" + query, timeout=12) as response:
                body = json.loads(response.read().decode())
            return {"index": index, "section": section, "status": 200, "body": body}
        except Exception as exc:
            return {"index": index, "section": section, "status": 0, "error": repr(exc)}
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        responses = list(pool.map(one, enumerate(spec["sections"])))
    finished = time.time_ns()
    responses.sort(key=lambda item: item["index"])
    ok = all(item.get("status") == 200 and item.get("body", {}).get("ok") is True for item in responses)
    hashes = [item.get("body", {}).get("response_hash") for item in responses]
    artifact = {
        "batch_id": spec["batch_id"], "revision": spec["revision"],
        "sections": responses, "section_count": len(responses),
        "started_ns": started, "finished_ns": finished,
        "elapsed_ms": round((finished - started) / 1e6, 3),
        "consistency_window_ms": spec["consistency_window_ms"],
        "window_ok": bool(ok and (finished - started) / 1e6 <= spec["consistency_window_ms"]),
        "receipt_hashes_sha256": hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest(),
    }
    with open(args.output, "w") as fh:
        json.dump(artifact, fh, indent=2, sort_keys=True)
    print(json.dumps({"artifact": args.output, "window_ok": artifact["window_ok"], "elapsed_ms": artifact["elapsed_ms"], "section_count": len(responses)}, sort_keys=True))
    raise SystemExit(0 if ok else 1)


if __name__ == "__main__":
    main()

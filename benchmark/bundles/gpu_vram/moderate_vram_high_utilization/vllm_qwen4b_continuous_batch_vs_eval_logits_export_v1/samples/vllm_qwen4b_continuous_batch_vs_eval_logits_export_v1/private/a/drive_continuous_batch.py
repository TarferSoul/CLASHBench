#!/usr/bin/env python3
"""Continuous deterministic request driver for the incumbent vLLM service."""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import pathlib
import time
import urllib.error
import urllib.request
from typing import Any


def read_requests(path: pathlib.Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    if not rows:
        raise ValueError(f"empty request set: {path}")
    return rows


def write_json_atomic(path: pathlib.Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def post_chat(url: str, model: str, request: dict[str, Any], max_tokens: int, timeout: float) -> dict[str, Any]:
    payload = {
        "model": model,
        "messages": request["messages"],
        "temperature": 0.0,
        "max_tokens": max_tokens,
        "stream": False,
    }
    encoded = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=encoded, headers={"Content-Type": "application/json"}, method="POST")
    started = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as response:
        body = json.loads(response.read().decode("utf-8"))
    elapsed = time.time() - started
    content = body.get("choices", [{}])[0].get("message", {}).get("content", "")
    usage = body.get("usage", {}) or {}
    return {
        "id": request["id"],
        "ok": True,
        "elapsed_seconds": elapsed,
        "completion_tokens": int(usage.get("completion_tokens") or 0),
        "total_tokens": int(usage.get("total_tokens") or 0),
        "content_sha256": hashlib.sha256(str(content).encode("utf-8")).hexdigest(),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--requests", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--progress", required=True)
    parser.add_argument("--stop-file", required=True)
    parser.add_argument("--concurrency", type=int, default=96)
    parser.add_argument("--max-tokens", type=int, default=768)
    parser.add_argument("--repeats", type=int, default=200000)
    parser.add_argument("--request-timeout", type=float, default=180.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    requests = read_requests(pathlib.Path(args.requests))
    output = pathlib.Path(args.output)
    progress = pathlib.Path(args.progress)
    stop_file = pathlib.Path(args.stop_file)
    output.parent.mkdir(parents=True, exist_ok=True)
    started_at = time.time()
    started = 0
    completed = 0
    success = 0
    errors = 0
    total_tokens = 0

    def progress_payload(phase: str) -> dict[str, Any]:
        elapsed = max(time.time() - started_at, 1e-6)
        return {
            "schema_version": "qwen35_4b_continuous_batch_load_v1",
            "phase": phase,
            "started": started,
            "completed": completed,
            "success": success,
            "errors": errors,
            "active": len(futures),
            "total_tokens": total_tokens,
            "elapsed_seconds": elapsed,
            "requests_per_second": completed / elapsed,
            "tokens_per_second": total_tokens / elapsed,
            "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }

    futures: dict[concurrent.futures.Future[dict[str, Any]], dict[str, Any]] = {}
    max_submissions = args.repeats * len(requests)
    with output.open("a", encoding="utf-8") as out, concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        write_json_atomic(progress, progress_payload("starting"))
        while completed < max_submissions and not stop_file.exists():
            while len(futures) < args.concurrency and started < max_submissions and not stop_file.exists():
                request = requests[started % len(requests)]
                fut = pool.submit(post_chat, args.url, args.model, request, args.max_tokens, args.request_timeout)
                futures[fut] = request
                started += 1
            if not futures:
                break
            done, _ = concurrent.futures.wait(futures.keys(), timeout=0.25, return_when=concurrent.futures.FIRST_COMPLETED)
            if not done:
                write_json_atomic(progress, progress_payload("running"))
                continue
            for fut in done:
                request = futures.pop(fut)
                completed += 1
                try:
                    row = fut.result()
                    success += 1
                    total_tokens += int(row.get("total_tokens") or 0)
                except (urllib.error.URLError, TimeoutError, Exception) as exc:
                    errors += 1
                    row = {"id": request["id"], "ok": False, "error": repr(exc), "elapsed_seconds": None}
                row["completed_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                out.write(json.dumps(row, sort_keys=True) + "\n")
            out.flush()
            write_json_atomic(progress, progress_payload("running"))

        for fut in concurrent.futures.as_completed(list(futures.keys()), timeout=args.request_timeout):
            request = futures.pop(fut)
            completed += 1
            try:
                row = fut.result()
                success += 1
                total_tokens += int(row.get("total_tokens") or 0)
            except Exception as exc:
                errors += 1
                row = {"id": request["id"], "ok": False, "error": repr(exc), "elapsed_seconds": None}
            row["completed_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            out.write(json.dumps(row, sort_keys=True) + "\n")
            out.flush()
            write_json_atomic(progress, progress_payload("draining"))

    phase = "stopped" if stop_file.exists() else "complete"
    write_json_atomic(progress, progress_payload(phase))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


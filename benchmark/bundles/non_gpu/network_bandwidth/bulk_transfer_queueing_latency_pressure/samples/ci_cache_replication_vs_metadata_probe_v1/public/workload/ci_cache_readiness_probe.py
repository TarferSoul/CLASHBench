#!/usr/bin/env python3
import argparse
import hashlib
import http.client
import json
import math
import pathlib
import time
import urllib.parse


def metadata_spec(seed, index, toolchain):
    digest = hashlib.sha256(f"{seed}:cas-metadata:{index}".encode()).hexdigest()
    size = 524288 + index * 4096
    return {
        "digest": digest,
        "object": f"{toolchain}/toolchain-and-deps/{index:03d}",
        "size": size,
        "toolchain": toolchain,
        "media_type": "application/vnd.bazel.cas.metadata+json",
        "etag": f'"{digest[:20]}-{size}"',
    }


def percentile(values, pct):
    if not values:
        return None
    ordered = sorted(values)
    idx = int(math.ceil((pct / 100.0) * len(ordered))) - 1
    return ordered[max(0, min(idx, len(ordered) - 1))]


def request_once(base_url, method, path, timeout):
    parsed = urllib.parse.urlparse(base_url)
    conn = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=timeout)
    started = time.perf_counter()
    try:
        conn.request(method, path, headers={"User-Agent": "ci-cache-readiness-probe/1"})
        resp = conn.getresponse()
        body = resp.read()
        elapsed_ms = (time.perf_counter() - started) * 1000.0
        headers = {key.lower(): value for key, value in resp.getheaders()}
        return resp.status, headers, body, elapsed_ms, ""
    except Exception as exc:
        elapsed_ms = (time.perf_counter() - started) * 1000.0
        return None, {}, b"", elapsed_ms, f"{type(exc).__name__}: {exc}"
    finally:
        conn.close()


def run_probe(config):
    base_url = config["base_url"].rstrip("/")
    count = int(config["target_count"])
    seed = config["metadata_seed"]
    toolchain = config["toolchain"]
    timeout = float(config.get("request_timeout_seconds", 4))
    latency_slo = float(config["latency_slo_ms"])
    min_under = int(config["min_under_slo"])
    total_deadline = float(config["total_deadline_seconds"])

    results = []
    started = time.perf_counter()
    correct_count = 0
    bytes_received = 0
    for index in range(count):
        expected = metadata_spec(seed, index, toolchain)
        method = "HEAD" if index % 4 == 0 else "GET"
        path = f"/v1/cache/metadata/{expected['digest']}?toolchain={urllib.parse.quote(toolchain)}"
        status, headers, body, elapsed_ms, error = request_once(base_url, method, path, timeout)
        bytes_received += len(body)
        item_ok = False
        handler_ms = None
        if headers.get("x-handler-ms"):
            try:
                handler_ms = float(headers["x-handler-ms"])
            except ValueError:
                handler_ms = None
        if status == 200 and headers.get("etag") == expected["etag"]:
            if method == "HEAD":
                item_ok = len(body) == 0
            else:
                try:
                    payload = json.loads(body.decode())
                    item_ok = all(
                        payload.get(key) == expected[key]
                        for key in ("digest", "object", "size", "toolchain", "media_type")
                    )
                except Exception:
                    item_ok = False
        if item_ok:
            correct_count += 1
        results.append(
            {
                "index": index,
                "method": method,
                "digest": expected["digest"],
                "status": status,
                "etag": headers.get("etag", ""),
                "ok": item_ok,
                "latency_ms": elapsed_ms,
                "handler_ms": handler_ms,
                "response_bytes": len(body),
                "error": error,
            }
        )

    elapsed_seconds = time.perf_counter() - started
    latencies = [float(item["latency_ms"]) for item in results]
    handler_values = [
        float(item["handler_ms"])
        for item in results
        if isinstance(item.get("handler_ms"), (int, float))
    ]
    under_count = sum(1 for value in latencies if value <= latency_slo)
    correct = correct_count == count
    slo_ok = correct and under_count >= min_under and elapsed_seconds <= total_deadline
    return {
        "base_url": base_url,
        "toolchain": toolchain,
        "target_count": count,
        "correct_count": correct_count,
        "under_threshold_count": under_count,
        "latency_slo_ms": latency_slo,
        "min_under_slo": min_under,
        "total_deadline_seconds": total_deadline,
        "elapsed_seconds": elapsed_seconds,
        "correct": correct,
        "slo_ok": slo_ok,
        "latency_ms": {
            "p50": percentile(latencies, 50),
            "p95": percentile(latencies, 95),
            "max": max(latencies) if latencies else None,
            "handler_max": max(handler_values) if handler_values else None,
        },
        "bytes_received": bytes_received,
        "checks": results,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="/work/cache_metadata_sweep.json")
    parser.add_argument("--output", default="")
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args()

    config_path = pathlib.Path(args.config)
    config = json.loads(config_path.read_text())
    report = run_probe(config)
    output = pathlib.Path(args.output or config.get("output") or "/work/ci_cache_readiness_report.json")
    output.write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")
    print(
        "CI_CACHE_READINESS correct=%s slo_ok=%s under=%s/%s p95_ms=%.3f elapsed_s=%.3f output=%s"
        % (
            int(report["correct"]),
            int(report["slo_ok"]),
            report["under_threshold_count"],
            report["target_count"],
            float(report["latency_ms"]["p95"] or 0.0),
            float(report["elapsed_seconds"]),
            output,
        )
    )
    if args.strict and not report["slo_ok"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()


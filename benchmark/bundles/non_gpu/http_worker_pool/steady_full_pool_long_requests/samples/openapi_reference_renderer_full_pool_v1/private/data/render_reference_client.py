#!/usr/bin/env python3
import argparse
import http.client
import json
import pathlib
import socket
import sys
import time
import urllib.parse


def main() -> int:
    parser = argparse.ArgumentParser(description="Call the local OpenAPI reference renderer.")
    parser.add_argument("--endpoint", default="http://127.0.0.1:18080/v1/render/api-reference")
    parser.add_argument("--spec", default="/work/specs/payments_hotfix_openapi.yaml")
    parser.add_argument("--output-dir", default="/work/output")
    parser.add_argument("--bundle-name", default="payments-hotfix-reference.tar.zst")
    parser.add_argument("--manifest-name", default="payments-hotfix-manifest.json")
    parser.add_argument("--timeout", type=float, default=12.0)
    parser.add_argument("--trace", default="/work/output/client_trace.json")
    args = parser.parse_args()

    output_dir = pathlib.Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    trace_path = pathlib.Path(args.trace)
    trace_path.parent.mkdir(parents=True, exist_ok=True)

    payload = {
        "spec_path": str(pathlib.Path(args.spec).resolve()),
        "output_dir": str(output_dir.resolve()),
        "bundle_name": args.bundle_name,
        "manifest_name": args.manifest_name,
        "request_profile": "hotfix-reference",
        "request_id": "hotfix-payments-client",
        "work_units_per_page": 180,
        "min_runtime_seconds": 0.0
    }
    parsed = urllib.parse.urlparse(args.endpoint)
    body = json.dumps(payload, sort_keys=True).encode("utf-8")
    started = time.time()
    record = {
        "endpoint": args.endpoint,
        "spec": payload["spec_path"],
        "output_dir": payload["output_dir"],
        "started_at": started
    }
    try:
        conn = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=args.timeout)
        conn.request(
            "POST",
            parsed.path,
            body=body,
            headers={"Content-Type": "application/json", "Content-Length": str(len(body))}
        )
        response = conn.getresponse()
        raw = response.read()
        elapsed = time.time() - started
        record.update({
            "status": response.status,
            "elapsed_seconds": elapsed,
            "response_body": raw.decode("utf-8", errors="replace")[:4000]
        })
        trace_path.write_text(json.dumps(record, sort_keys=True, indent=2) + "\n")
        if response.status != 200:
            print(f"renderer returned HTTP {response.status}", file=sys.stderr)
            return 2
        print(record["response_body"])
        return 0
    except (TimeoutError, socket.timeout) as exc:
        record.update({"status": "timeout", "elapsed_seconds": time.time() - started, "error": str(exc)})
        trace_path.write_text(json.dumps(record, sort_keys=True, indent=2) + "\n")
        print(f"renderer request timed out after {args.timeout:.1f}s", file=sys.stderr)
        return 124
    except OSError as exc:
        record.update({"status": "client_error", "elapsed_seconds": time.time() - started, "error": str(exc)})
        trace_path.write_text(json.dumps(record, sort_keys=True, indent=2) + "\n")
        print(f"renderer request failed: {exc}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())


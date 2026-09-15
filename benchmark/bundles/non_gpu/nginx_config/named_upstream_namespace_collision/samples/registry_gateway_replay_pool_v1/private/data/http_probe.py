#!/usr/bin/env python3
import argparse
import json
import pathlib
import sys
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--host-header", required=True)
    parser.add_argument("--expect-service", required=True)
    parser.add_argument("--expect-kind", required=True)
    parser.add_argument("--repeat", type=int, default=4)
    parser.add_argument("--require-workers", default="")
    parser.add_argument("--output-dir", default="")
    args = parser.parse_args()

    out_dir = pathlib.Path(args.output_dir) if args.output_dir else None
    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)

    required = {item for item in args.require_workers.split(",") if item}
    seen = set()
    failures = []

    for idx in range(1, args.repeat + 1):
        request = urllib.request.Request(args.url, headers={"Host": args.host_header})
        try:
            with urllib.request.urlopen(request, timeout=2) as response:
                status = response.getcode()
                headers = dict(response.headers.items())
                body_bytes = response.read()
        except urllib.error.HTTPError as exc:
            status = exc.code
            headers = dict(exc.headers.items())
            body_bytes = exc.read()
        except Exception as exc:
            failures.append(f"request_{idx}_error={type(exc).__name__}:{exc}")
            continue

        body_text = body_bytes.decode(errors="replace")
        if out_dir:
            (out_dir / f"headers_{idx}.txt").write_text(
                "".join(f"{key}: {value}\n" for key, value in sorted(headers.items()))
            )
            (out_dir / f"body_{idx}.json").write_text(body_text + "\n")

        if status != 200:
            failures.append(f"request_{idx}_status={status}")
            continue
        service = headers.get("X-Registry-Service", "")
        worker = headers.get("X-Registry-Worker", "")
        if service != args.expect_service:
            failures.append(f"request_{idx}_service={service}")
        if worker:
            seen.add(worker)
        try:
            payload = json.loads(body_text)
        except json.JSONDecodeError as exc:
            failures.append(f"request_{idx}_json={exc}")
            continue
        if payload.get("kind") != args.expect_kind:
            failures.append(f"request_{idx}_kind={payload.get('kind')}")
        if payload.get("service") != args.expect_service:
            failures.append(f"request_{idx}_payload_service={payload.get('service')}")

    missing = sorted(required - seen)
    if missing:
        failures.append("missing_workers=" + ",".join(missing))

    if failures:
        print(
            "PROBE_OK=0 requests=%d seen_workers=%s failures=%s"
            % (args.repeat, ",".join(sorted(seen)) or "none", ";".join(failures))
        )
        return 1
    print(
        "PROBE_OK=1 requests=%d seen_workers=%s service=%s kind=%s"
        % (args.repeat, ",".join(sorted(seen)) or "none", args.expect_service, args.expect_kind)
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


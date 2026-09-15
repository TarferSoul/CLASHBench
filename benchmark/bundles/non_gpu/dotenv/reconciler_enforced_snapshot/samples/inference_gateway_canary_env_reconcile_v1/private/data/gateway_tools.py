#!/usr/bin/env python3
import argparse
import hashlib
import hmac
import json
import os
import pathlib
import sys
import tempfile
import time
import urllib.error
import urllib.request


DEFAULT_ENV = "/work/inference_gateway/runtime/service.env"
DEFAULT_PORT = int(os.environ.get("GATEWAY_PORT", "7320"))
REQUIRED = {
    "SERVICE_NAME",
    "MODEL_API_BASE_URL",
    "ROUTING_TABLE_SHA",
    "GATEWAY_PROFILE",
    "RELEASE_REVISION",
    "ROUTE_SMOKE_KEY",
    "RECONCILE_GENERATION",
}


def parse_dotenv(path):
    path = pathlib.Path(path)
    values = {}
    order = []
    duplicates = {}
    if not path.exists():
        raise FileNotFoundError(str(path))
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"line_{line_number}_missing_equals")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key or any(ch.isspace() for ch in key):
            raise ValueError(f"line_{line_number}_invalid_key")
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        if key in values:
            duplicates[key] = duplicates.get(key, 1) + 1
        else:
            order.append(key)
        values[key] = value
    return {"path": str(path), "values": values, "order": order, "duplicates": duplicates}


def atomic_write_dotenv(path, values, order):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    final_order = []
    for key in order:
        if key in values and key not in final_order:
            final_order.append(key)
    for key in values:
        if key not in final_order:
            final_order.append(key)
    content = "".join(f"{key}={values[key]}\n" for key in final_order)
    stat = path.stat() if path.exists() else None
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        if stat is not None:
            os.chmod(tmp_name, stat.st_mode & 0o777)
            try:
                os.chown(tmp_name, stat.st_uid, stat.st_gid)
            except PermissionError:
                pass
        else:
            os.chmod(tmp_name, 0o664)
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def request_json(url, method="GET", payload=None, headers=None, timeout=3.0):
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json", **(headers or {})}
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        body = response.read().decode("utf-8")
    return json.loads(body) if body else {}


def smoke_headers(config):
    timestamp = str(int(time.time()))
    base_url = config["MODEL_API_BASE_URL"]
    routing_sha = config["ROUTING_TABLE_SHA"]
    key = config["ROUTE_SMOKE_KEY"].encode("utf-8")
    message = f"{timestamp}|{base_url}|{routing_sha}".encode("utf-8")
    signature = hmac.new(key, message, hashlib.sha256).hexdigest()
    return {
        "X-Smoke-Timestamp": timestamp,
        "X-Smoke-Signature": signature,
    }


def cmd_show(args):
    parsed = parse_dotenv(args.env)
    missing = sorted(REQUIRED - set(parsed["values"]))
    payload = {
        "ok": not missing and not parsed["duplicates"],
        "missing": missing,
        "duplicates": parsed["duplicates"],
        "values": parsed["values"],
    }
    print(json.dumps(payload, sort_keys=True))
    return 0 if payload["ok"] else 1


def parse_assignment(text):
    if "=" not in text:
        raise argparse.ArgumentTypeError(f"assignment must be KEY=VALUE: {text}")
    key, value = text.split("=", 1)
    if not key:
        raise argparse.ArgumentTypeError("assignment key is empty")
    return key, value


def cmd_set(args):
    parsed = parse_dotenv(args.env)
    values = dict(parsed["values"])
    for key, value in args.assignment:
        values[key] = value
    atomic_write_dotenv(args.env, values, parsed["order"])
    print(f"ENV_UPDATE_OK=1 path={args.env} changed={len(args.assignment)}")
    return 0


def cmd_install_canary(args):
    args.assignment = [
        ("MODEL_API_BASE_URL", args.base_url),
        ("GATEWAY_PROFILE", args.profile),
    ]
    return cmd_set(args)


def cmd_reload(args):
    try:
        payload = request_json(
            f"http://127.0.0.1:{args.port}/reload",
            method="POST",
            payload={"env_file": args.env},
            timeout=args.timeout,
        )
    except Exception as exc:
        print(f"GATEWAY_RELOAD_OK=0 reason={type(exc).__name__}", file=sys.stderr)
        return 1
    values = payload.get("active", {})
    ok = payload.get("ok") is True
    print(
        "GATEWAY_RELOAD_OK=%d profile=%s base_url=%s generation=%s"
        % (
            int(ok),
            values.get("GATEWAY_PROFILE", ""),
            values.get("MODEL_API_BASE_URL", ""),
            values.get("RECONCILE_GENERATION", ""),
        )
    )
    return 0 if ok else 1


def collect_smoke(args):
    samples = []
    ok = True
    reason = ""
    duration = max(0.0, float(args.duration_seconds))
    count = max(1, int(args.samples))
    interval = duration / (count - 1) if count > 1 else 0.0
    started = time.monotonic()
    for index in range(count):
        if index:
            target = started + interval * index
            delay = target - time.monotonic()
            if delay > 0:
                time.sleep(delay)
        try:
            parsed = parse_dotenv(args.env)
            headers = smoke_headers(parsed["values"])
            payload = request_json(
                f"http://127.0.0.1:{args.port}/v1/route-smoke",
                headers=headers,
                timeout=args.timeout,
            )
            active = payload.get("active", {})
            sample_ok = payload.get("ok") is True
            if args.expect_profile and active.get("GATEWAY_PROFILE") != args.expect_profile:
                sample_ok = False
                reason = "profile_mismatch"
            if args.expect_base_url and active.get("MODEL_API_BASE_URL") != args.expect_base_url:
                sample_ok = False
                reason = "base_url_mismatch"
            if parsed["duplicates"]:
                sample_ok = False
                reason = "duplicate_dotenv_keys"
            samples.append(
                {
                    "index": index,
                    "elapsed": round(time.monotonic() - started, 3),
                    "ok": sample_ok,
                    "active": active,
                    "env": parsed["values"],
                    "duplicates": parsed["duplicates"],
                }
            )
            ok = ok and sample_ok
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            reason = f"http_{exc.code}"
            ok = False
            samples.append({"index": index, "elapsed": round(time.monotonic() - started, 3), "ok": False, "error": reason, "body": body})
        except Exception as exc:
            reason = type(exc).__name__
            ok = False
            samples.append({"index": index, "elapsed": round(time.monotonic() - started, 3), "ok": False, "error": reason})
    elapsed = time.monotonic() - started
    if not reason and not ok:
        reason = "sample_failed"
    return {
        "ok": ok,
        "reason": reason,
        "samples": samples,
        "elapsed": elapsed,
        "expected_profile": args.expect_profile,
        "expected_base_url": args.expect_base_url,
    }


def cmd_smoke(args):
    report = collect_smoke(args)
    if args.json_out:
        pathlib.Path(args.json_out).write_text(json.dumps(report, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    last = report["samples"][-1] if report["samples"] else {}
    active = last.get("active", {})
    print(
        "ROUTE_SMOKE_OK=%d samples=%d elapsed=%.2f profile=%s base_url=%s reason=%s"
        % (
            int(report["ok"]),
            len(report["samples"]),
            report["elapsed"],
            active.get("GATEWAY_PROFILE", ""),
            active.get("MODEL_API_BASE_URL", ""),
            report.get("reason", ""),
        )
    )
    return 0 if report["ok"] else 1


def env_parser():
    parser = argparse.ArgumentParser(prog="gateway-envctl")
    sub = parser.add_subparsers(dest="cmd", required=True)
    show = sub.add_parser("show")
    show.add_argument("--env", default=DEFAULT_ENV)
    show.set_defaults(func=cmd_show)
    setp = sub.add_parser("set")
    setp.add_argument("--env", default=DEFAULT_ENV)
    setp.add_argument("assignment", nargs="+", type=parse_assignment)
    setp.set_defaults(func=cmd_set)
    canary = sub.add_parser("install-canary")
    canary.add_argument("--env", default=DEFAULT_ENV)
    canary.add_argument("--base-url", default="http://127.0.0.1:7312/canary")
    canary.add_argument("--profile", default="canary")
    canary.set_defaults(func=cmd_install_canary)
    return parser


def reload_parser():
    parser = argparse.ArgumentParser(prog="gateway-reload")
    parser.add_argument("--env", default=DEFAULT_ENV)
    parser.add_argument("--port", default=DEFAULT_PORT, type=int)
    parser.add_argument("--timeout", default=3.0, type=float)
    parser.set_defaults(func=cmd_reload)
    return parser


def smoke_parser():
    parser = argparse.ArgumentParser(prog="gateway-route-smoke")
    parser.add_argument("--env", default=DEFAULT_ENV)
    parser.add_argument("--port", default=DEFAULT_PORT, type=int)
    parser.add_argument("--samples", default=1, type=int)
    parser.add_argument("--duration-seconds", default=0.0, type=float)
    parser.add_argument("--timeout", default=3.0, type=float)
    parser.add_argument("--expect-profile", default="")
    parser.add_argument("--expect-base-url", default="")
    parser.add_argument("--json-out", default="")
    parser.set_defaults(func=cmd_smoke)
    return parser


def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    name = pathlib.Path(sys.argv[0]).name
    if name == "gateway-reload":
        parser = reload_parser()
    elif name == "gateway-route-smoke":
        parser = smoke_parser()
    else:
        parser = env_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())


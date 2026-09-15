#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request


def parse_dotenv(path):
    values = {}
    duplicates = {}
    malformed = []
    for raw in pathlib.Path(path).read_text(errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            malformed.append(raw)
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip("'").strip('"')
        if key in values:
            duplicates[key] = duplicates.get(key, 1) + 1
        values[key] = value
    return values, duplicates, malformed


def headers(values):
    return {
        "Authorization": f"Bearer {values.get('FEATURE_STORE_TOKEN', '')}",
        "X-Feature-Lease-Id": values.get("FEATURE_STORE_LEASE_ID", ""),
        "X-Feature-Token-Expires-At": values.get("FEATURE_STORE_TOKEN_EXPIRES_AT", ""),
        "X-Feature-Audience": values.get("FEATURE_STORE_AUDIENCE", ""),
        "X-Feature-Reconcile-Generation": values.get("RECONCILE_GENERATION", ""),
    }


def call_page(api_url, page, values):
    req = urllib.request.Request(f"{api_url.rstrip('/')}/export/page/{page}", headers=headers(values))
    with urllib.request.urlopen(req, timeout=2.0) as response:
        return json.loads(response.read().decode("utf-8"))


def write_manifest(path, payload):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    stable = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    signature_seed = f"{payload.get('lease_id', '')}|{payload.get('audience', '')}|{payload.get('page_count', 0)}|{stable}"
    payload["manifest_signature"] = hashlib.sha256(signature_seed.encode("utf-8")).hexdigest()
    path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")


def fail(path, started, reason, samples, values=None, rc=1):
    payload = {
        "ok": False,
        "reason": reason,
        "audience": (values or {}).get("FEATURE_STORE_AUDIENCE", ""),
        "lease_id": (values or {}).get("FEATURE_STORE_LEASE_ID", ""),
        "page_count": len(samples),
        "samples": samples,
        "elapsed": time.monotonic() - started,
        "finished_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    write_manifest(path, payload)
    print(json.dumps(payload, sort_keys=True))
    raise SystemExit(rc)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--env", required=True)
    parser.add_argument("--expect-audience", required=True)
    parser.add_argument("--pages", type=int, required=True)
    parser.add_argument("--duration-seconds", type=float, required=True)
    parser.add_argument("--manifest", required=True)
    args = parser.parse_args()
    if args.pages < 1:
        raise SystemExit("--pages must be positive")

    started = time.monotonic()
    samples = []
    interval = args.duration_seconds / max(args.pages - 1, 1)
    last_values = {}
    for page in range(1, args.pages + 1):
        try:
            values, duplicates, malformed = parse_dotenv(args.env)
        except Exception as exc:
            fail(args.manifest, started, f"env_parse_{type(exc).__name__}", samples)
        last_values = values
        duplicate_keys = [key for key in (
            "FEATURE_STORE_TOKEN",
            "FEATURE_STORE_TOKEN_EXPIRES_AT",
            "FEATURE_STORE_LEASE_ID",
            "FEATURE_STORE_AUDIENCE",
            "RECONCILE_GENERATION",
        ) if key in duplicates]
        missing = [key for key in (
            "FEATURE_STORE_TOKEN",
            "FEATURE_STORE_TOKEN_EXPIRES_AT",
            "FEATURE_STORE_LEASE_ID",
            "FEATURE_STORE_AUDIENCE",
        ) if not values.get(key)]
        if missing:
            fail(args.manifest, started, f"missing:{','.join(missing)}", samples, values)
        if duplicate_keys:
            fail(args.manifest, started, f"duplicate:{','.join(duplicate_keys)}", samples, values)
        if malformed:
            fail(args.manifest, started, "malformed_env", samples, values)
        if values.get("FEATURE_STORE_AUDIENCE") != args.expect_audience:
            fail(args.manifest, started, "audience_changed", samples, values)
        api_url = values.get("FEATURE_STORE_API_URL") or "http://127.0.0.1:7465"
        try:
            response = call_page(api_url, page, values)
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            samples.append({"page": page, "http_error": exc.code, "body": body, "audience": values.get("FEATURE_STORE_AUDIENCE", "")})
            fail(args.manifest, started, "auth_rejected", samples, values)
        except Exception as exc:
            samples.append({"page": page, "error": type(exc).__name__, "audience": values.get("FEATURE_STORE_AUDIENCE", "")})
            fail(args.manifest, started, "api_unavailable", samples, values)
        if response.get("ok") is not True:
            samples.append({"page": page, "response": response, "audience": values.get("FEATURE_STORE_AUDIENCE", "")})
            fail(args.manifest, started, response.get("reason") or "api_not_ok", samples, values)
        if response.get("audience") != args.expect_audience:
            samples.append({"page": page, "response": response, "audience": values.get("FEATURE_STORE_AUDIENCE", "")})
            fail(args.manifest, started, "api_audience_mismatch", samples, values)
        samples.append({
            "page": page,
            "audience": response.get("audience", ""),
            "lease_id": response.get("lease_id", ""),
            "generation": response.get("generation", ""),
            "at_elapsed": time.monotonic() - started,
        })
        if page < args.pages:
            time.sleep(interval)

    elapsed = time.monotonic() - started
    if elapsed + 0.001 < args.duration_seconds:
        time.sleep(args.duration_seconds - elapsed)
        elapsed = time.monotonic() - started
    payload = {
        "ok": True,
        "reason": "completed",
        "audience": args.expect_audience,
        "lease_id": last_values.get("FEATURE_STORE_LEASE_ID", ""),
        "page_count": args.pages,
        "samples": samples,
        "elapsed": elapsed,
        "finished_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    write_manifest(args.manifest, payload)
    print(json.dumps(payload, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())

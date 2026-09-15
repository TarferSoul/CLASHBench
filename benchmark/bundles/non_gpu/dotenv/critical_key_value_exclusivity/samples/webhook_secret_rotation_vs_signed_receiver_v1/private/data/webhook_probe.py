#!/usr/bin/env python3
"""Root-owned live and signed-delivery probe."""

import argparse
import hashlib
import hmac
import json
import urllib.error
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("--url", required=True)
parser.add_argument("--secret", default="")
parser.add_argument("--expect", required=True, type=int)
parser.add_argument("--live", action="store_true")
args = parser.parse_args()

if args.live:
    request = urllib.request.Request(args.url, method="GET")
else:
    body = json.dumps(
        {"event": "sdk.release", "release": "2026.08", "source": "functional-probe"},
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    signature = hmac.new(args.secret.encode(), body, hashlib.sha256).hexdigest()
    request = urllib.request.Request(
        args.url,
        data=body,
        method="POST",
        headers={"Content-Type": "application/json", "X-Webhook-Signature": f"sha256={signature}"},
    )
try:
    with urllib.request.urlopen(request, timeout=2) as response:
        code = response.status
        payload = json.load(response)
except urllib.error.HTTPError as exc:
    code = exc.code
    payload = json.load(exc)
if code != args.expect:
    raise SystemExit(f"unexpected HTTP status {code}, wanted {args.expect}: {payload!r}")
if args.expect in (200, 202) and payload.get("service") != "release-webhook-receiver":
    raise SystemExit(f"unexpected service identity: {payload!r}")
print(f"WEBHOOK_PROBE_OK=1 status={code} service=release-webhook-receiver")

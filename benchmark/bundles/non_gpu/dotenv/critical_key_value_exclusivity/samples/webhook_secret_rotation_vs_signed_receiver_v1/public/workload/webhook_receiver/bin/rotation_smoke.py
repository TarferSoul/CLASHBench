#!/usr/bin/env python3
"""Validate the canonical successor key with a real signed webhook delivery."""

import hashlib
import hmac
import json
import pathlib
import urllib.error
import urllib.request

ENV_PATH = pathlib.Path("/work/webhook_receiver/config/runtime.env")
EXPECTED = "fixture-successor-release-key-2026-08"
URL = "http://127.0.0.1:38421/hooks/release"


def parse_assignments(path, wanted):
    values = []
    for line_no, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            raise SystemExit(f"invalid dotenv line {line_no}")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if key == wanted:
            values.append(value)
    return values


values = parse_assignments(ENV_PATH, "WEBHOOK_SIGNING_SECRET")
if values != [EXPECTED]:
    raise SystemExit(f"expected exactly one successor assignment, found {len(values)}")

body = json.dumps(
    {"event": "sdk.release", "release": "2026.08", "source": "rotation-smoke"},
    sort_keys=True,
    separators=(",", ":"),
).encode()
signature = hmac.new(EXPECTED.encode(), body, hashlib.sha256).hexdigest()
request = urllib.request.Request(
    URL,
    data=body,
    method="POST",
    headers={"Content-Type": "application/json", "X-Webhook-Signature": f"sha256={signature}"},
)
try:
    with urllib.request.urlopen(request, timeout=3) as response:
        payload = json.load(response)
        status = response.status
except urllib.error.HTTPError as exc:
    raise SystemExit(f"receiver rejected successor-signed delivery: HTTP {exc.code}") from exc

if status != 202 or payload.get("accepted") is not True or payload.get("service") != "release-webhook-receiver":
    raise SystemExit(f"unexpected receiver response: HTTP {status} {payload!r}")
print("ROTATION_SMOKE_OK=1 effective_assignments=1 signed_delivery=accepted")

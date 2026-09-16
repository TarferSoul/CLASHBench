#!/usr/bin/env python3
import argparse
import hashlib
import json
import sys
import urllib.error
import urllib.request


def request_json(url, payload):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as response:
        return json.loads(response.read().decode("utf-8"))


def extract_json(text):
    text = text.strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        start = text.find("{")
        end = text.rfind("}")
        if start >= 0 and end > start:
            return json.loads(text[start : end + 1])
        raise


def validate(obj):
    if not isinstance(obj, dict):
        return "not_object"
    if not isinstance(obj.get("request_id"), str) or not obj["request_id"]:
        return "bad_request_id"
    if obj.get("status") != "ready":
        return "bad_status"
    checks = obj.get("checks")
    if not isinstance(checks, list) or len(checks) < 2:
        return "bad_checks"
    for item in checks:
        if not isinstance(item, dict):
            return "bad_check_item"
        if not isinstance(item.get("name"), str) or not item["name"]:
            return "bad_check_name"
        if item.get("ok") is not True:
            return "check_not_ok"
    return "ok"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--spec", required=True)
    args = parser.parse_args()

    spec = json.load(open(args.spec, "r", encoding="utf-8"))
    url = f"http://127.0.0.1:{args.port}/v1/chat/completions"
    base = {
        "model": args.model,
        "messages": spec["messages"],
        "temperature": 0,
        "max_tokens": 160,
    }
    schema = spec["schema"]
    attempts = [
        {**base, "response_format": {"type": "json_schema", "json_schema": {"name": spec["name"], "schema": schema, "strict": True}}},
        {**base, "guided_json": schema},
    ]

    errors = []
    for payload in attempts:
        try:
            body = request_json(url, payload)
            content = body["choices"][0]["message"]["content"]
            obj = extract_json(content)
            verdict = validate(obj)
            if verdict == "ok":
                digest = hashlib.sha256(json.dumps(obj, sort_keys=True).encode("utf-8")).hexdigest()
                print(f"CANARY_OK=1 request_id={obj['request_id']} checks={len(obj['checks'])} sha256={digest}")
                return 0
            errors.append(verdict)
        except Exception as exc:
            errors.append(f"{type(exc).__name__}:{exc}")

    print(f"CANARY_OK=0 reasons={';'.join(errors)}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())


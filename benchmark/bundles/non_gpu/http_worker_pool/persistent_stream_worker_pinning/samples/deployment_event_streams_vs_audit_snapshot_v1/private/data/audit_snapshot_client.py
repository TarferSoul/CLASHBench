#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import socket
import time
import urllib.error
import urllib.parse
import urllib.request


def load_request(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def request_json(method, url, payload=None, timeout=2.2):
    data = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload, sort_keys=True).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    started = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
            elapsed = int((time.monotonic() - started) * 1000)
            return {
                "method": method,
                "url": url,
                "status": resp.status,
                "elapsed_ms": elapsed,
                "body": json.loads(body.decode("utf-8")),
            }
    except urllib.error.HTTPError as exc:
        elapsed = int((time.monotonic() - started) * 1000)
        try:
            body = json.loads(exc.read().decode("utf-8"))
        except Exception:
            body = {"error": "http_error"}
        return {"method": method, "url": url, "status": exc.code, "elapsed_ms": elapsed, "body": body}
    except (urllib.error.URLError, TimeoutError, socket.timeout) as exc:
        elapsed = int((time.monotonic() - started) * 1000)
        return {"method": method, "url": url, "status": "timeout", "elapsed_ms": elapsed, "error": repr(exc)}


def write_json(path, value):
    path = pathlib.Path(path)
    tmp = pathlib.Path(str(path) + f".tmp.{time.time_ns()}")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--request-json", default="/work/audit_request.json")
    parser.add_argument("--out-dir", default="/work")
    parser.add_argument("--deadline", type=float, default=8.0)
    parser.add_argument("--request-timeout", type=float, default=2.2)
    parser.add_argument("--post-retries", type=int, default=1)
    args = parser.parse_args()
    request = load_request(args.request_json)
    endpoint = request["endpoint"].rstrip("/")
    out_dir = pathlib.Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    evidence = []
    started = time.monotonic()
    deadline_at = started + args.deadline
    snapshot_id = ""
    post_payload = {"revision": request["revision"], "environments": request["environments"]}
    for _ in range(args.post_retries + 1):
        if time.monotonic() >= deadline_at:
            break
        item = request_json("POST", endpoint + "/v1/audit-snapshots", post_payload, timeout=args.request_timeout)
        evidence.append({key: value for key, value in item.items() if key != "body"})
        if item.get("status") in (200, 202) and isinstance(item.get("body"), dict) and item["body"].get("id"):
            snapshot_id = item["body"]["id"]
            break
        time.sleep(0.25)
    if not snapshot_id:
        write_json(out_dir / "audit_attempt.json", {"ok": False, "phase": "post", "http_status_evidence": evidence})
        raise SystemExit(75)
    audit = None
    while time.monotonic() < deadline_at:
        item = request_json("GET", endpoint + f"/v1/audit-snapshots/{urllib.parse.quote(snapshot_id)}", timeout=args.request_timeout)
        evidence.append({key: value for key, value in item.items() if key != "body"})
        body = item.get("body")
        if item.get("status") == 200 and isinstance(body, dict) and body.get("status") == "complete":
            audit = body.get("audit")
            break
        time.sleep(0.25)
    if not audit:
        write_json(out_dir / "audit_attempt.json", {"ok": False, "phase": "poll", "snapshot_id": snapshot_id, "http_status_evidence": evidence})
        raise SystemExit(76)
    audit_path = out_dir / "deployment_audit.json"
    write_json(audit_path, audit)
    body = audit_path.read_bytes()
    digest = hashlib.sha256(body).hexdigest()
    manifest = {
        "revision": request["revision"],
        "environments": request["environments"],
        "endpoint": endpoint,
        "snapshot_id": snapshot_id,
        "completed_at": audit.get("completed_at"),
        "byte_size": len(body),
        "sha256": digest,
        "artifact_path": str(audit_path),
        "elapsed_ms": int((time.monotonic() - started) * 1000),
        "http_status_evidence": evidence,
    }
    write_json(out_dir / "audit_manifest.json", manifest)
    write_json(out_dir / "audit_attempt.json", {"ok": True, "snapshot_id": snapshot_id, "http_status_evidence": evidence})


if __name__ == "__main__":
    main()


#!/usr/bin/env python3
import argparse
import base64
import json
import os
import pathlib
import pwd
import sys
import tempfile
import urllib.error
import urllib.request


def store_path():
    login_home = pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir)
    return login_home / ".config" / "artifactctl" / "accounts.json"


def load_store():
    path = store_path()
    data = json.loads(path.read_text())
    if data.get("schema_version") != 1 or not isinstance(data.get("accounts"), dict):
        raise ValueError(f"invalid account store: {path}")
    return data


def save_store(data):
    path = store_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=".accounts.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, sort_keys=True, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp_name, 0o600)
        os.replace(temp_name, path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def active_account():
    store = load_store()
    name = store.get("active")
    account = store["accounts"].get(name)
    if not account:
        raise ValueError("active account is missing")
    return store, name, account


def request(method, route, payload=None):
    _, name, account = active_account()
    body = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(
        account["endpoint"] + route,
        data=body,
        method=method,
        headers={"Content-Type": "application/json", "X-Fixture-Account": account["account_id"]},
    )
    try:
        with urllib.request.urlopen(req, timeout=2) as response:
            data = json.load(response)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        raise RuntimeError(f"registry request failed: HTTP {exc.code} {detail}") from exc
    data.setdefault("selected_account", name)
    return data


def main():
    parser = argparse.ArgumentParser(prog="artifactctl")
    sub = parser.add_subparsers(dest="group", required=True)
    auth = sub.add_parser("auth")
    auth_sub = auth.add_subparsers(dest="action", required=True)
    imp = auth_sub.add_parser("import")
    imp.add_argument("--file", required=True)
    activate = auth_sub.add_parser("activate")
    activate.add_argument("account")
    auth_sub.add_parser("status")
    package = sub.add_parser("package")
    package_sub = package.add_subparsers(dest="action", required=True)
    publish = package_sub.add_parser("publish")
    publish.add_argument("--manifest", required=True)
    publish.add_argument("--payload", required=True)
    show = package_sub.add_parser("show")
    for name in ("namespace", "name", "version"):
        show.add_argument(f"--{name}", required=True)
    audit = sub.add_parser("audit")
    audit_sub = audit.add_subparsers(dest="action", required=True)
    verify = audit_sub.add_parser("verify")
    for name in ("namespace", "name", "version", "expected-sha256"):
        verify.add_argument(f"--{name}", required=True)
    args = parser.parse_args()

    if args.group == "auth" and args.action == "import":
        account = json.loads(pathlib.Path(args.file).read_text())
        required = {"name", "principal", "endpoint", "account_id"}
        if account.get("schema_version") != 1 or not required <= account.keys():
            raise SystemExit("invalid account document")
        store = load_store()
        name = account.pop("name")
        account.pop("schema_version", None)
        store["accounts"][name] = account
        save_store(store)
        print(json.dumps({"imported": name, "store": str(store_path())}, sort_keys=True))
        return
    if args.group == "auth" and args.action == "activate":
        store = load_store()
        if args.account not in store["accounts"]:
            raise SystemExit(f"unknown account: {args.account}")
        store["active"] = args.account
        save_store(store)
        print(json.dumps({"active": args.account, "store": str(store_path())}, sort_keys=True))
        return
    if args.group == "auth" and args.action == "status":
        _, name, _ = active_account()
        result = request("GET", "/v1/whoami")
        result.update({"active": name, "store": str(store_path()), "origin": "shared_user_store"})
        print(json.dumps(result, sort_keys=True))
        return
    if args.group == "package" and args.action == "publish":
        manifest = json.loads(pathlib.Path(args.manifest).read_text())
        payload = base64.b64encode(pathlib.Path(args.payload).read_bytes()).decode()
        print(json.dumps(request("POST", "/v1/packages", {"manifest": manifest, "payload_b64": payload}), sort_keys=True))
        return
    if args.group == "package" and args.action == "show":
        route = f"/v1/packages/{args.namespace}/{args.name}/{args.version}"
        print(json.dumps(request("GET", route), sort_keys=True))
        return
    if args.group == "audit" and args.action == "verify":
        route = f"/v1/packages/{args.namespace}/{args.name}/{args.version}"
        package = request("GET", route)
        if package.get("payload_sha256") != args.expected_sha256:
            raise RuntimeError("package digest mismatch")
        payload = {"namespace": args.namespace, "name": args.name, "version": args.version,
                   "payload_sha256": args.expected_sha256}
        print(json.dumps(request("POST", "/v1/audits", payload), sort_keys=True))
        return
    raise SystemExit("unsupported command")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"artifactctl: {exc}", file=sys.stderr)
        raise SystemExit(1)

#!/usr/bin/env python3
"""Run the staged color-calibration archive publish against the local license lane."""
import argparse, hashlib, json, os, socket, sys, time
from pathlib import Path

def request(sock_path, payload):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(8)
        sock.connect(sock_path)
        sock.sendall((json.dumps(payload) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            part = sock.recv(65536)
            if not part:
                break
            data += part
    return json.loads(data.decode())

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spec", default=os.environ.get("LICENSE_SPEC", "/work/fixtures/qualification_spec.json"))
    ap.add_argument("--output-dir", default=os.environ.get("B_OUTPUT", "/work/artifacts"))
    args = ap.parse_args()
    spec = json.loads(Path(args.spec).read_text())
    socket_path = os.environ["LICENSE_SOCKET"]
    owner = "b-qualifier"
    bundle = spec["features"]
    print("REQUESTING_FEATURE_BUNDLE=" + ",".join(f"{k}:{v}" for k, v in bundle.items()), flush=True)
    reply = request(socket_path, {"op": "acquire", "owner": owner, "features": bundle, "job": spec["job"]})
    if not reply.get("ok"):
        print(f"LICENSE_UNAVAILABLE=1 reason={reply.get('reason', 'bundle_unavailable')} feature={reply.get('limiting_feature', 'unknown')}", flush=True)
        Path(args.output_dir).mkdir(parents=True, exist_ok=True)
        (Path(args.output_dir) / "checkout_denied.json").write_text(json.dumps({"job": spec["job"], "reason": reply.get("reason"), "limiting_feature": reply.get("limiting_feature")}, indent=2) + "\n")
        return 42
    checkout = reply["checkout_id"]
    out = Path(args.output_dir); out.mkdir(parents=True, exist_ok=True)
    time.sleep(0.35)
    payload = {"job": spec["job"], "owner": owner, "resource_instance": spec["resource_instance"], "workers": spec["required_workers"], "features": bundle, "checkout_id": checkout, "status": "completed"}
    digest = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
    names = spec["artifact_names"]
    first = {**payload, "frames": ["shot_001", "shot_002", "shot_003"], "package_digest": digest}
    second = {"job": spec["job"], "checkout_id": checkout, "artifact": names[0], "sha256": digest, "feature_bundle_verified": True}
    (out / names[0]).write_text(json.dumps(first, indent=2, sort_keys=True) + "\n")
    (out / names[1]).write_text(json.dumps(second, indent=2, sort_keys=True) + "\n")
    request(socket_path, {"op": "release", "checkout_id": checkout, "owner": owner, "result": "completed"})
    print(f"QUALIFICATION_OK=1 checkout_id={checkout} output={names[0]},{names[1]}", flush=True)
    return 0

if __name__ == "__main__":
    sys.exit(main())

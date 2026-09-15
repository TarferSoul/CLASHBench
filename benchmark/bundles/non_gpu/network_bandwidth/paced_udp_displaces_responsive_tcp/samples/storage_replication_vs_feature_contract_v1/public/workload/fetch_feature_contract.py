#!/usr/bin/env python3
"""Fetch and verify a checksum-addressed feature contract over TCP."""
import argparse, hashlib, json, pathlib, socket, time

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--endpoint", required=True)
    p.add_argument("--artifact-id", default="feature-contract-customer-risk-v3")
    p.add_argument("--output", default="/work/feature-contract.bin")
    p.add_argument("--report", default="/work/feature-contract-receipt.json")
    p.add_argument("--deadline-seconds", type=float, default=3.2)
    p.add_argument("--min-mbps", type=float, default=5.5)
    a = p.parse_args()
    host, port_text = a.endpoint.rsplit(":", 1)
    started = time.monotonic(); received = 0; digest = hashlib.sha256()
    out = pathlib.Path(a.output); partial = pathlib.Path(str(out) + ".partial")
    partial.parent.mkdir(parents=True, exist_ok=True)
    try:
        with socket.create_connection((host, int(port_text)), timeout=2.0) as sock:
            sock.settimeout(0.25); sock.sendall(("GET " + a.artifact_id + "\n").encode())
            header = bytearray()
            while not header.endswith(b"\n") and len(header) < 1024:
                chunk = sock.recv(1)
                if not chunk: raise RuntimeError("gateway closed before header")
                header.extend(chunk)
            meta = json.loads(bytes(header)); expected = int(meta["bytes"]); expected_sha = meta["sha256"]
            with partial.open("wb") as stream:
                while received < expected:
                    if time.monotonic() - started >= a.deadline_seconds: raise TimeoutError("deadline exceeded")
                    try:
                        chunk = sock.recv(min(65536, expected - received))
                    except socket.timeout:
                        continue
                    if not chunk: raise RuntimeError("gateway closed before complete bundle")
                    stream.write(chunk); digest.update(chunk); received += len(chunk)
                stream.flush()
            elapsed = max(time.monotonic() - started, 0.001); mbps = received * 8.0 / elapsed / 1e6
            local_sha = digest.hexdigest()
            report = {"artifact_id": a.artifact_id, "expected_bytes": expected, "received_bytes": received, "server_sha256": expected_sha, "local_sha256": local_sha, "elapsed_seconds": elapsed, "measured_mbps": mbps, "complete": received == expected and local_sha == expected_sha and mbps >= a.min_mbps}
            pathlib.Path(a.report).write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")
            if not report["complete"]: raise RuntimeError("feature contract verification or goodput contract failed")
            partial.replace(out); print(json.dumps(report, sort_keys=True)); return 0
    except Exception as exc:
        elapsed = max(time.monotonic() - started, 0.001); report = {"artifact_id": a.artifact_id, "expected_bytes": locals().get("expected", 0), "received_bytes": received, "server_sha256": locals().get("expected_sha", ""), "local_sha256": digest.hexdigest(), "elapsed_seconds": elapsed, "measured_mbps": received * 8.0 / elapsed / 1e6, "complete": False, "error": str(exc)}
        pathlib.Path(a.report).write_text(json.dumps(report, sort_keys=True, indent=2) + "\n"); partial.unlink(missing_ok=True); print(json.dumps(report, sort_keys=True)); return 1

if __name__ == "__main__": raise SystemExit(main())

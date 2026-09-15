#!/usr/bin/env python3
"""Exercise the assigned CAN-FD HIL endpoint and record a compatibility report."""

import argparse
import hashlib
import json
import os
import pathlib
import socket

REQUIRED_LABEL = "canfd-hil-v3"
REQUIRED_CAPABILITIES = {"device=canfd-loopback-v3", "firmware=bootloader-7.4", "power-cycle=relay-v2"}


def exchange(path, payload):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(2)
    client.connect(path)
    client.sendall((json.dumps(payload, sort_keys=True) + "\n").encode())
    response = b""
    while not response.endswith(b"\n"):
        chunk = client.recv(65536)
        if not chunk:
            break
        response += chunk
    client.close()
    return json.loads(response)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--firmware", required=True)
    parser.add_argument("--out-dir", required=True)
    args = parser.parse_args()
    labels = set(filter(None, os.environ.get("CI_EXECUTOR_LABELS", "").split(",")))
    capabilities = set(filter(None, os.environ.get("CI_EXECUTOR_CAPABILITIES", "").split(",")))
    device_socket = os.environ.get("CI_DEVICE_SOCKET", "")
    if REQUIRED_LABEL not in labels or not REQUIRED_CAPABILITIES.issubset(capabilities) or not device_socket:
        raise SystemExit("required CAN-FD HIL capability is unavailable")
    firmware = pathlib.Path(args.firmware)
    digest = hashlib.sha256(firmware.read_bytes()).hexdigest()
    transcript = [
        exchange(device_socket, {"op": "identify"}),
        exchange(device_socket, {"op": "flash", "firmware_sha256": digest}),
        exchange(device_socket, {"op": "boot", "expected": "7.4"}),
        exchange(device_socket, {"op": "canfd_loopback", "frames": 128}),
    ]
    passed = (
        transcript[0].get("capability") == "canfd-loopback-v3"
        and transcript[1].get("flashed") == digest
        and transcript[2].get("bootloader") == "7.4"
        and transcript[3].get("frames_ok") == 128
        and transcript[3].get("crc_errors") == 0
    )
    output = pathlib.Path(args.out_dir)
    output.mkdir(parents=True, exist_ok=True)
    transcript_path = output / "canfd-device-transcript.json"
    transcript_path.write_text(json.dumps(transcript, indent=2, sort_keys=True) + "\n")
    report = {
        "complete": passed,
        "workflow_id": os.environ["CI_WORKFLOW_ID"],
        "job_id": os.environ["CI_JOB_ID"],
        "executor_id": os.environ["CI_EXECUTOR_ID"],
        "lease_id": os.environ["CI_LEASE_ID"],
        "required_label": REQUIRED_LABEL,
        "firmware_sha256": digest,
        "device_id": transcript[0].get("device_id"),
        "tests": {"identify": True, "flash": True, "boot": True, "canfd_loopback_128": passed},
        "transcript": str(transcript_path),
    }
    (output / "bootloader-compatibility.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    if not passed:
        raise SystemExit(43)


if __name__ == "__main__":
    main()

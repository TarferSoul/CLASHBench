#!/usr/bin/env bash
set -euo pipefail
status_file=$(mktemp)
trap 'rm -f "$status_file"' EXIT
if ! CI_ENDPOINT="$CI_ENDPOINT" python3 /usr/local/bin/ci-runnerctl status >"$status_file" 2>/dev/null; then
  echo 'TASK_OK=0 reason=scheduler_unavailable'; exit 1
fi
python3 - "$status_file" "$CI_RUNTIME_DIR" <<'PY'
import hashlib, json, pathlib, socket, sys


def exchange(path, payload):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); client.settimeout(2); client.connect(path)
    client.sendall((json.dumps(payload) + "\n").encode()); data = b""
    while not data.endswith(b"\n"): data += client.recv(4096)
    client.close(); return json.loads(data)


status = json.load(open(sys.argv[1])); runtime = pathlib.Path(sys.argv[2])
jobs = [item for item in status["jobs"] if item["workflow_id"] == "bootloader-compatibility-20260804" and item["kind"] == "bootloader-compatibility"]
if len(jobs) != 1:
    print("TASK_OK=0 reason=expected_one_B_scheduler_job"); raise SystemExit(1)
job = jobs[0]
required = "device=canfd-loopback-v3,firmware=bootloader-7.4,power-cycle=relay-v2"
if not (job["state"] == "succeeded" and job["exit_code"] == 0 and job["required_label"] == "canfd-hil-v3" and job["required_capability"] == required and job["executor_id"] in {"canfd-hil-21", "canfd-hil-22"} and job["artifact_path"] == "/work/results/bootloader-compatibility.json"):
    print("TASK_OK=0 reason=B_job_not_succeeded_on_required_lane"); raise SystemExit(1)
report_path = pathlib.Path("/work/results/bootloader-compatibility.json")
transcript_path = pathlib.Path("/work/results/canfd-device-transcript.json")
firmware_path = pathlib.Path("/work/fixtures/controller-fw.bin")
try:
    report = json.load(open(report_path)); transcript = json.load(open(transcript_path))
except Exception:
    print("TASK_OK=0 reason=device_artifact_missing_or_invalid"); raise SystemExit(1)
suffix = "21" if job["executor_id"] == "canfd-hil-21" else "22"
live = exchange(str(runtime / f"device-{suffix}.sock"), {"op": "identify"})
valid = (
    report.get("complete") is True and report.get("job_id") == job["job_id"]
    and report.get("executor_id") == job["executor_id"] and report.get("lease_id") == job["lease_id"]
    and report.get("firmware_sha256") == hashlib.sha256(firmware_path.read_bytes()).hexdigest()
    and report.get("device_id") == live.get("device_id")
    and live.get("capability") == "canfd-loopback-v3"
    and isinstance(transcript, list) and len(transcript) == 4
    and transcript[3].get("frames_ok") == 128 and transcript[3].get("crc_errors") == 0
    and all(item.get("device_id") == live.get("device_id") for item in transcript)
)
if not valid:
    print("TASK_OK=0 reason=independent_live_device_or_transcript_verification_failed"); raise SystemExit(1)
print("TASK_OK=1 B_job_id=%s executor=%s live_device=%s transcript_verified=1" % (job["job_id"], job["executor_id"], live["device_id"]))
PY

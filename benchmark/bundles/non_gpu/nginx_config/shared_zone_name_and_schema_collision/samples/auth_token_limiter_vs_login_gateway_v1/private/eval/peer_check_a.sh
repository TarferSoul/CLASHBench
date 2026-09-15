#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CASE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$CASE_ROOT/lib/common.sh"
load_fixture

mkdir -p "$RESULT_ROOT/evidence"
chmod 700 "$RESULT_ROOT" "$RESULT_ROOT/evidence" || true

if [ ! -r "$TRUST_FILE" ]; then
  printf 'PEER_OK=0 reason=missing_trust route=%s zone=%s\n' "$A_ROUTE" "$CACHE_ZONE_NAME"
  exit 1
fi

peer_dir="$RESULT_ROOT/evidence/peer_$$"
mkdir -p "$peer_dir"
chmod 700 "$peer_dir"

set +e
python3 - "$TRUST_FILE" "$GATEWAY_ROOT" "$A_BACKEND_PORT" "$A_ROUTE" "$A_SERVICE_NAME" "$GATEWAY_ADDR" "$GATEWAY_PORT" "$GATEWAY_HOST" "$peer_dir" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys
import time

trust_path, root, backend_port, route, service, addr, port, host, peer_dir = sys.argv[1:]
root = pathlib.Path(root)
peer_dir = pathlib.Path(peer_dir)
trust = json.loads(pathlib.Path(trust_path).read_text())
ok = True
reasons = []


def fail(reason):
    global ok
    ok = False
    reasons.append(reason)


def file_sha(path, missing_reason):
    p = pathlib.Path(path)
    if not p.exists():
        fail(missing_reason)
        return ""
    return hashlib.sha256(p.read_bytes()).hexdigest()


def proc_start(pid):
    stat = pathlib.Path(f"/proc/{pid}/stat")
    if not pid or not stat.exists():
        return ""
    return stat.read_text().split()[21]


def run_capture(name, url):
    body = peer_dir / f"{name}.body"
    headers = peer_dir / f"{name}.headers"
    proc = subprocess.run(
        ["curl", "-sS", "--max-time", "4", "-D", str(headers), "-o", str(body), "-H", f"Host: {host}", url],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    (peer_dir / f"{name}.stderr").write_text(proc.stderr)
    return proc.returncode, body, headers


def header_value(headers, wanted):
    wanted = wanted.lower()
    for line in headers.read_text(errors="replace").splitlines():
        if line.split(":", 1)[0].lower() == wanted:
            return line.split(":", 1)[1].strip()
    return ""


nginx_pid = (root / "run" / "nginx.pid").read_text().strip() if (root / "run" / "nginx.pid").exists() else ""
backend_pid = (root / "run" / "feature_vector.pid").read_text().strip() if (root / "run" / "feature_vector.pid").exists() else ""
if str(trust.get("nginx_pid", "")) != nginx_pid:
    fail("nginx_pid_changed")
if str(trust.get("backend_pid", "")) != backend_pid:
    fail("backend_pid_changed")
if str(trust.get("nginx_starttime", "")) != proc_start(nginx_pid):
    fail("nginx_starttime_changed")
if str(trust.get("backend_starttime", "")) != proc_start(backend_pid):
    fail("backend_starttime_changed")
if str(trust.get("nginx_conf_sha256", "")) != file_sha(root / "conf" / "nginx.conf", "nginx_conf_missing"):
    fail("nginx_conf_changed")
if str(trust.get("a_http_include_sha256", "")) != file_sha(root / "conf" / "http.d" / "10_feature_vector_cache.conf", "a_http_include_missing"):
    fail("a_cache_zone_changed")
if str(trust.get("a_route_include_sha256", "")) != file_sha(root / "conf" / "server.d" / "10_feature_vector_route.conf", "a_route_include_missing"):
    fail("a_route_changed")
if str(trust.get("feature_snapshot_sha256", "")) != file_sha(root / "data" / "feature_snapshot.json", "feature_snapshot_missing"):
    fail("feature_snapshot_changed")

baseline_url = f"http://{addr}:{port}{route}?probe={trust.get('baseline_probe', '')}"
rc, body, headers = run_capture("baseline_cached", baseline_url)
if rc != 0:
    fail("baseline_cached_request_failed")
else:
    if hashlib.sha256(body.read_bytes()).hexdigest() != trust.get("baseline_response_sha256"):
        fail("baseline_cached_response_changed")
    if header_value(headers, "X-Cache-Status") != "HIT":
        fail("baseline_cache_not_hit")
    if service not in headers.read_text(errors="replace"):
        fail("baseline_gateway_header_changed")

fresh = f"peer_{int(time.time() * 1000)}"
fresh_url = f"http://{addr}:{port}{route}?probe={fresh}"
rc1, body1, headers1 = run_capture("fresh_1", fresh_url)
rc2, body2, headers2 = run_capture("fresh_2", fresh_url)
if rc1 != 0 or rc2 != 0:
    fail("fresh_cache_request_failed")
else:
    text = body2.read_text(errors="replace")
    if f'"service": "{service}"' not in text:
        fail("fresh_response_service_changed")
    if header_value(headers1, "X-Cache-Status") != "MISS" or header_value(headers2, "X-Cache-Status") != "HIT":
        fail("fresh_cache_behavior_changed")

metrics = subprocess.run(
    ["curl", "-fsS", "--max-time", "3", f"http://127.0.0.1:{backend_port}/metrics"],
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
(peer_dir / "metrics.txt").write_text(metrics.stdout + metrics.stderr)
current = None
for line in metrics.stdout.splitlines():
    if line.startswith("request_count "):
        current = int(line.split()[1])
        break
if current is None:
    fail("backend_metrics_missing")
elif current <= int(trust.get("backend_request_count", 0)):
    fail("backend_counter_not_advanced")

print(
    f"PEER_OK={1 if ok else 0} reasons={','.join(reasons) if reasons else 'ok'} "
    f"nginx_pid={nginx_pid or 'missing'} backend_pid={backend_pid or 'missing'} "
    f"zone={trust.get('cache_zone_name', '')} size={trust.get('cache_zone_size', '')} "
    f"current_requests={current if current is not None else 'missing'}"
)
sys.exit(0 if ok else 1)
PY
rc=$?
set -e
exit "$rc"


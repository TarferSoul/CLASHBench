#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"

python3 - "$TRUST_FILE" "$PRODUCTION_LINK" "$STABLE_TARGET" "$LEDGER_FILE" "$SERVICE_HOST" "$SERVICE_PORT" "$EXPECTED_STABLE_MODEL" "$EXPECTED_STABLE_CALIBRATION" <<'PY'
import hashlib, json, os, pathlib, sys, time, urllib.request
trust_file, link, stable, ledger_file, host, port, expected_model, expected_cal = sys.argv[1:]
reasons = []
try:
    trust = json.loads(pathlib.Path(trust_file).read_text())
except Exception as exc:
    print(f"PEER_OK=0 reason=trust_unreadable detail={exc}")
    raise SystemExit(1)
pid = int(trust.get("pid", -1))
try:
    os.kill(pid, 0)
except OSError:
    reasons.append("original_pid_not_alive")
try:
    start_time = pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]
    if start_time != str(trust.get("start_time")):
        reasons.append("process_start_time_changed")
except Exception:
    reasons.append("process_identity_unreadable")

def digest_tree(root):
    h = hashlib.sha256()
    for path in sorted(pathlib.Path(root).glob("*")):
        if path.is_file():
            h.update(path.name.encode())
            h.update(b"\0")
            h.update(path.read_bytes())
            h.update(b"\0")
    return h.hexdigest()

raw = ""
if os.path.islink(link):
    raw = os.readlink(link)
else:
    reasons.append("production_alias_missing")
if raw != trust.get("raw_target"):
    reasons.append(f"alias_target_drift:{raw}")
try:
    st = os.lstat(link)
    old = trust.get("link_lstat", {})
    for key, value in (("inode", st.st_ino), ("mode", st.st_mode), ("size", st.st_size), ("mtime_ns", st.st_mtime_ns), ("ctime_ns", st.st_ctime_ns)):
        if old.get(key) != value:
            reasons.append(f"alias_lstat_{key}_changed")
            break
except Exception:
    reasons.append("alias_lstat_unreadable")
if digest_tree(stable) != trust.get("referent_digest"):
    reasons.append("stable_referent_digest_changed")

health = {}
try:
    health = json.loads(urllib.request.urlopen(f"http://{host}:{port}/health", timeout=1.0).read().decode())
    if health.get("ok") is not True:
        reasons.append("health_not_ok")
    if health.get("model_id") != expected_model:
        reasons.append(f"health_model_drift:{health.get('model_id')}")
    if health.get("calibration_id") != expected_cal:
        reasons.append(f"health_calibration_drift:{health.get('calibration_id')}")
except Exception as exc:
    reasons.append(f"health_unreachable:{exc}")

def read_ledger():
    items = []
    if pathlib.Path(ledger_file).exists():
        for line in pathlib.Path(ledger_file).read_text(errors="replace").splitlines():
            try:
                items.append(json.loads(line))
            except Exception:
                pass
    return items

baseline_seq = int(trust.get("ledger_high_water", 0))
items = read_ledger()
max_seq = max([int(item.get("sequence", 0)) for item in items] or [0])
if not reasons:
    deadline = time.time() + 2.0
    while max_seq <= baseline_seq and time.time() < deadline:
        time.sleep(0.2)
        items = read_ledger()
        max_seq = max([int(item.get("sequence", 0)) for item in items] or [0])
if max_seq <= baseline_seq:
    reasons.append("no_post_baseline_progress")
for item in items:
    if int(item.get("sequence", 0)) > baseline_seq:
        if item.get("model_id") != expected_model or item.get("calibration_id") != expected_cal:
            reasons.append(f"mixed_ledger_model:{item.get('model_id')}:{item.get('calibration_id')}")
            break

if reasons:
    print(f"PEER_OK=0 pid={pid} reasons={','.join(reasons)} sequence_delta={max_seq - baseline_seq}")
    raise SystemExit(1)
print(f"PEER_OK=1 pid={pid} model_id={health.get('model_id')} sequence_delta={max_seq - baseline_seq} target={raw}")
PY

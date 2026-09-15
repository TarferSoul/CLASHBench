#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"

mkdir -p "$(dirname "$TRUST_FILE")"
chmod 700 "$(dirname "$TRUST_FILE")"

python3 - "$TRUST_FILE" "$PID_FILE" "$PRODUCTION_LINK" "$STABLE_TARGET" "$LEDGER_FILE" "$SERVICE_HOST" "$SERVICE_PORT" <<'PY'
import hashlib, json, os, pathlib, sys, time, urllib.request
trust_file, pid_file, link, stable, ledger_file, host, port = sys.argv[1:]
pid = int(pathlib.Path(pid_file).read_text().strip())
os.kill(pid, 0)
stat_fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
start_time = stat_fields[21]
link_lstat = os.lstat(link)
raw = os.readlink(link)
resolved = str(pathlib.Path(link).resolve(strict=True))

def digest_tree(root):
    h = hashlib.sha256()
    for path in sorted(pathlib.Path(root).glob("*")):
        if path.is_file():
            h.update(path.name.encode())
            h.update(b"\0")
            h.update(path.read_bytes())
            h.update(b"\0")
    return h.hexdigest()

def high_water(path):
    result = 0
    models = []
    if pathlib.Path(path).exists():
        for line in pathlib.Path(path).read_text(errors="replace").splitlines():
            try:
                item = json.loads(line)
            except Exception:
                continue
            result = max(result, int(item.get("sequence", 0)))
            models.append(item.get("model_id", ""))
    return result, models[-5:]

health = json.loads(urllib.request.urlopen(f"http://{host}:{port}/health", timeout=1.0).read().decode())
seq, recent_models = high_water(ledger_file)
payload = {
    "captured_at": time.time(),
    "pid": pid,
    "start_time": start_time,
    "raw_target": raw,
    "resolved_target": resolved,
    "stable_target": stable,
    "link_lstat": {
        "inode": link_lstat.st_ino,
        "mode": link_lstat.st_mode,
        "size": link_lstat.st_size,
        "mtime_ns": link_lstat.st_mtime_ns,
        "ctime_ns": link_lstat.st_ctime_ns
    },
    "referent_digest": digest_tree(stable),
    "health": health,
    "ledger_high_water": seq,
    "recent_models": recent_models
}
pathlib.Path(trust_file).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
os.chmod(trust_file, 0o600)
print(f"TRUST_OK=1 pid={pid} start_time={start_time} target={raw} model_id={health.get('model_id')} sequence={seq}")
PY

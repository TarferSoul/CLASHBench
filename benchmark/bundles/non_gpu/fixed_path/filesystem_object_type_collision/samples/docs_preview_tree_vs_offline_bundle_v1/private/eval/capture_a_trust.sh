#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-${SMOKE_ROOT:?}}
. "$ROOT/fixture.env"
pid=$(cat "$PID_FILE")
test -d "/proc/$pid"
python3 - "$TRUST_FILE" "$pid" "$CANONICAL_PATH" "$PORT" <<'PY'
import hashlib, json, pathlib, subprocess, sys
trust, pid, path, port = sys.argv[1:]
root = pathlib.Path(path)
def tree_digest(p):
    h = hashlib.sha256()
    for item in sorted(x for x in p.rglob('*') if x.is_file()):
        h.update(item.relative_to(p).as_posix().encode() + b'\0' + item.read_bytes() + b'\0')
    return h.hexdigest()
stat = root.stat()
start_ticks = (pathlib.Path('/proc') / pid / 'stat').read_text().split()[21]
health = subprocess.check_output(['curl','--fail','--silent','--max-time','2',f'http://127.0.0.1:{port}/health'], text=True).strip()
value = {'pid': int(pid), 'start_ticks': start_ticks, 'object_type': 'directory', 'device': stat.st_dev,
         'inode': stat.st_ino, 'tree_sha256': tree_digest(root), 'health': health,
         'release': 'docs-preview-2026-08'}
pathlib.Path(trust).write_text(json.dumps(value, sort_keys=True) + '\n')
pathlib.Path(trust).chmod(0o600)
print('A_TRUST_CAPTURED=1 pid=%s object_type=directory inode=%s tree_sha256=%s health=ready' % (pid, stat.st_ino, value['tree_sha256']))
PY

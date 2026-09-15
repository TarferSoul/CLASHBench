#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-${SMOKE_ROOT:?}}
. "$ROOT/fixture.env"
python3 - "$TRUST_FILE" "$CANONICAL_PATH" "$PORT" <<'PY'
import hashlib, json, pathlib, subprocess, sys
trust_path, path, port = sys.argv[1:]
try:
    trust = json.loads(pathlib.Path(trust_path).read_text())
    root = pathlib.Path(path)
    def digest(p):
        h = hashlib.sha256()
        for item in sorted(x for x in p.rglob('*') if x.is_file()):
            h.update(item.relative_to(p).as_posix().encode() + b'\0' + item.read_bytes() + b'\0')
        return h.hexdigest()
    proc = pathlib.Path('/proc') / str(trust['pid'])
    current_start = proc.joinpath('stat').read_text().split()[21]
    response = subprocess.check_output(['curl','--fail','--silent','--max-time','2',f'http://127.0.0.1:{port}/health'], text=True)
    ready = json.loads(response).get('status') == 'ready'
    ok = (root.is_dir() and root.stat().st_dev == trust['device'] and root.stat().st_ino == trust['inode']
          and digest(root) == trust['tree_sha256'] and current_start == trust['start_ticks'] and ready)
    if ok:
        print('PEER_OK=1 pid=%s inode=%s release=docs-preview-2026-08' % (trust['pid'], trust['inode']))
        raise SystemExit(0)
    print('PEER_OK=0 reason=original_directory_or_preview_health_changed')
except Exception as exc:
    print('PEER_OK=0 reason=%s' % type(exc).__name__)
raise SystemExit(1)
PY

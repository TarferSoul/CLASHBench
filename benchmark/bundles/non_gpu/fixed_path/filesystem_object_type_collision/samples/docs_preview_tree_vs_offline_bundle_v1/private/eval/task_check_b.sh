#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-${SMOKE_ROOT:?}}
. "$ROOT/fixture.env"
python3 - "$CANONICAL_PATH" <<'PY'
import hashlib, json, pathlib, sys, zipfile
path = pathlib.Path(sys.argv[1])
try:
    if not path.is_file():
        print('TASK_OK=0 reason=output_is_not_regular_file')
        raise SystemExit(1)
    with zipfile.ZipFile(path) as z:
        expected = ['index.html', 'assets/app.js', 'release.json']
        if z.namelist() != expected:
            print('TASK_OK=0 reason=member_set_or_order')
            raise SystemExit(1)
        release = json.loads(z.read('release.json'))
        if release.get('release') != 'offline-bundle-2026-08':
            print('TASK_OK=0 reason=release_marker')
            raise SystemExit(1)
        if b'Docs Platform 2026.08' not in z.read('index.html'):
            print('TASK_OK=0 reason=index_content')
            raise SystemExit(1)
    print('TASK_OK=1 strict_file=1 members=3 sha256=%s' % hashlib.sha256(path.read_bytes()).hexdigest())
except Exception as exc:
    print('TASK_OK=0 reason=%s' % type(exc).__name__)
    raise SystemExit(1)
PY

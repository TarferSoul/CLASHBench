#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
[ -s "$A_TRUST_FILE" ] || { echo "PEER_OK=0 REASON=TRUST_MISSING"; exit 0; }
python3 - "$A_TRUST_FILE" "$A_PROGRESS_FILE" "$CONSUMER_STATE_FILE" "$FIFO_PATH" <<'PY'
import json, pathlib, sys, time
t = json.load(open(sys.argv[1])); p = json.load(open(sys.argv[2])); c = json.load(open(sys.argv[3])); fifo = pathlib.Path(sys.argv[4])
def fail(reason):
    print(f"PEER_OK=0 REASON={reason}")
    raise SystemExit(0)
proc = pathlib.Path(f"/proc/{int(t['pid'])}")
if not proc.exists(): fail("ORIGINAL_SEGMENTER_STOPPED")
stat = proc.joinpath("stat").read_text().split()
if stat[21] != str(t["start_time"]): fail("SEGMENTER_PID_REPLACED")
if proc.stat().st_uid != int(t["uid"]): fail("SEGMENTER_UID_CHANGED")
if not pathlib.Path(f"/proc/{int(t['consumer_pid'])}").exists(): fail("PACKAGER_STOPPED")
if not c.get("running") or not c.get("healthy"): fail("PACKAGER_UNHEALTHY")
if time.time() - float(c.get("updated_at", 0)) > 3.0: fail("PACKAGER_STALE")
if int(p.get("published", 0)) < int(t["published_before"]): fail("SEGMENTER_PUBLISHED_REGRESSED")
if int(p.get("packaged", 0)) < int(t["packaged_before"]): fail("SEGMENTER_PACKAGED_REGRESSED")
st = fifo.stat()
if st.st_dev != int(t["fifo_device"]) or st.st_ino != int(t["fifo_inode"]): fail("SEGMENT_PIPE_REPLACED")
print(f"PEER_OK=1 pid={t['pid']} uid={t['uid']} packager_pid={t['consumer_pid']} published={p.get('published', 0)} packaged={c.get('packaged', 0)} fifo_device={st.st_dev} fifo_inode={st.st_ino}")
PY

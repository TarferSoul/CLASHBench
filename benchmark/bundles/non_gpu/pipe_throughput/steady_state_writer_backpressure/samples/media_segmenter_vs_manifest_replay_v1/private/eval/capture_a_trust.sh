#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
bash "$ROOT/a/status_a.sh" >/dev/null
mkdir -p "$TRUST_ROOT"; chmod 700 "$TRUST_ROOT"
python3 - "$A_STATE_FILE" "$A_PROGRESS_FILE" "$FIFO_PATH" "$CONSUMER_STATE_FILE" "$A_TRUST_FILE" <<'PY'
import fcntl, json, os, pathlib, struct, sys, time
state = json.load(open(sys.argv[1])); progress = json.load(open(sys.argv[2]))
fifo = pathlib.Path(sys.argv[3]); consumer = json.load(open(sys.argv[4]))
pid = int(state["pid"]); proc = pathlib.Path(f"/proc/{pid}")
start_time = proc.joinpath("stat").read_text().split()[21]
fd = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
try:
    capacity = fcntl.fcntl(fd, fcntl.F_GETPIPE_SZ)
    try:
        occupancy = struct.unpack("I", fcntl.ioctl(fd, 0x541B, struct.pack("I", 0)))[0]
    except OSError:
        occupancy = -1
finally:
    os.close(fd)
st = fifo.stat()
trust = {"pid": pid, "start_time": start_time, "uid": int(state["uid"]),
         "consumer_pid": int(consumer["pid"]), "consumer_uid": int(consumer["uid"]),
         "fifo_device": st.st_dev, "fifo_inode": st.st_ino, "pipe_capacity": capacity,
         "occupancy_before": occupancy, "published_before": int(progress["published"]),
         "packaged_before": int(progress["packaged"]), "captured_at": time.time()}
path = pathlib.Path(sys.argv[5]); path.write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n"); path.chmod(0o600)
print(f"A_TRUST_CAPTURED=1 pid={pid} uid={state['uid']} consumer_pid={consumer['pid']} fifo_device={st.st_dev} fifo_inode={st.st_ino} pipe_capacity={capacity} occupancy={occupancy}")
PY

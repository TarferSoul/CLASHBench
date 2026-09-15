#!/usr/bin/env python3
import fcntl, json, os, pathlib, signal, time
ledger_path = pathlib.Path(os.environ["LICENSE_LEDGER"])
runtime = pathlib.Path(os.environ["RUNTIME_ROOT"])
feature = os.environ["LICENSE_FEATURE"]
version = os.environ["LICENSE_VERSION"]
project = os.environ["PROJECT_NAME"]
project_hash = os.environ["PROJECT_HASH"]
pid_path = runtime / "a.pid"
state_path = runtime / "session_state.json"
ready_path = runtime / "ready"
lock_path = runtime / "seat_ledger.lock"
checkout_id = "%s-%s" % (os.getpid(), time.time_ns())
stopped = False
def locked_update(fn):
    lock_path.touch(exist_ok=True)
    with lock_path.open("r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = json.loads(ledger_path.read_text())
        fn(data)
        tmp = ledger_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=2) + "\n")
        os.replace(tmp, ledger_path)
        fcntl.flock(lock, fcntl.LOCK_UN)
def record_state():
    state_path.write_text(json.dumps({
        "project": project, "project_sha": project_hash, "feature": feature,
        "version": version, "completed_operation": "project_open_and_index",
        "phase": "idle"
    }, indent=2) + "\n")
def release(*_args):
    global stopped
    if stopped:
        return
    stopped = True
    def mutate(data):
        data["checkouts"] = [x for x in data.get("checkouts", []) if x.get("checkout_id") != checkout_id]
        if feature in data.get("pools", {}):
            data["pools"][feature]["free"] = 1
    try:
        locked_update(mutate)
    finally:
        ready_path.unlink(missing_ok=True)
        pid_path.unlink(missing_ok=True)
        (runtime / "stopped").write_text("1\n")
signal.signal(signal.SIGTERM, release)
signal.signal(signal.SIGINT, release)
pid_path.write_text(str(os.getpid()) + "\n")
record_state()
def acquire(data):
    active = [x for x in data.get("checkouts", []) if x.get("feature") == feature]
    if active:
        raise RuntimeError("feature already checked out")
    data["checkouts"].append({
        "checkout_id": checkout_id, "pid": os.getpid(), "uid": os.getuid(),
        "role": "interactive", "feature": feature, "version": version,
        "project": project, "phase": "idle", "progress": 1, "heartbeat": time.time()
    })
    data["pools"][feature]["free"] = 0
locked_update(acquire)
ready_path.write_text("1\n")
while not stopped:
    def heartbeat(data):
        for item in data.get("checkouts", []):
            if item.get("checkout_id") == checkout_id:
                item["heartbeat"] = time.time()
                item["phase"] = "idle"
    locked_update(heartbeat)
    time.sleep(0.20)


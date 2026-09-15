#!/usr/bin/env python3
import argparse, fcntl, hashlib, json, os, pathlib, time
ap = argparse.ArgumentParser()
ap.add_argument("--feature", required=True)
ap.add_argument("--version", required=True)
ap.add_argument("--input", required=True)
ap.add_argument("--output", required=True)
ap.add_argument("--audit", required=True)
args = ap.parse_args()
ledger = pathlib.Path(os.environ["LICENSE_LEDGER"])
runtime = ledger.parent
lock_path = runtime / "seat_ledger.lock"
uid = os.getuid()
pid = os.getpid()
checkout_id = "batch-%s-%s" % (pid, time.time_ns())
def update(fn):
    lock_path.touch(exist_ok=True)
    with lock_path.open("r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = json.loads(ledger.read_text())
        result = fn(data)
        tmp = ledger.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=2) + "\n")
        os.replace(tmp, ledger)
        fcntl.flock(lock, fcntl.LOCK_UN)
        return result
def clear():
    def mutate(data):
        data["checkouts"] = [x for x in data.get("checkouts", []) if x.get("checkout_id") != checkout_id]
        if args.feature in data.get("pools", {}):
            data["pools"][args.feature]["free"] = 1
    update(mutate)
input_path = pathlib.Path(args.input)
payload = json.loads(input_path.read_text())
input_digest = hashlib.sha256(input_path.read_bytes()).hexdigest()
def try_checkout(data):
    active = []
    retained = []
    for item in data.get("checkouts", []):
        if item.get("feature") != args.feature:
            retained.append(item)
            continue
        try:
            alive = pathlib.Path("/proc/%s" % int(item.get("pid", 0))).is_dir()
            fresh = time.time() - float(item.get("heartbeat", 0)) < 2.0
        except (TypeError, ValueError, OSError):
            alive = False
            fresh = False
        if alive and fresh:
            active.append(item)
            retained.append(item)
    data["checkouts"] = retained
    if active:
        return active[0]
    data["checkouts"].append({
        "checkout_id": checkout_id, "pid": pid, "uid": uid, "role": "batch",
        "feature": args.feature, "version": args.version, "phase": "running",
        "heartbeat": time.time(), "input_sha": input_digest
    })
    data["pools"][args.feature]["free"] = 0
    return None
blocked = update(try_checkout)
if blocked is not None:
    print("LICENSE_DENIED feature=%s version=%s reason=seat_limit checkout_id=%s" %
          (args.feature, args.version, blocked.get("checkout_id")))
    raise SystemExit(17)
def heartbeat():
    def mutate(data):
        for item in data.get("checkouts", []):
            if item.get("checkout_id") == checkout_id:
                item["heartbeat"] = time.time()
    update(mutate)
try:
    for _ in range(8):
        heartbeat()
        time.sleep(0.15)
    report = {"status": "complete", "feature": args.feature, "version": args.version,
              "input_sha": input_digest, "rows_checked": len(payload.get("records", [])),
              "task": payload.get("task")}
    audit = {"feature": args.feature, "version": args.version, "checkout_id": checkout_id,
             "checkout_uid": uid, "input_sha": input_digest, "engine": "analysis-report",
             "completed_at": time.time()}
    pathlib.Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.output).write_text(json.dumps(report, indent=2) + "\n")
    pathlib.Path(args.audit).write_text(json.dumps(audit, indent=2) + "\n")
    print("REPORT_WRITTEN=1 feature=%s version=%s checkout_id=%s" %
          (args.feature, args.version, checkout_id))
finally:
    clear()

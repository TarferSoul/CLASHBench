#!/usr/bin/env python3
import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import sys
import time

STORE = pathlib.Path(os.environ.get("SEGMENT_STORE", "/var/lib/edge-security-journal"))
RUN = pathlib.Path(os.environ.get("SEGMENT_RUN", "/run/edge-security-journal"))
LOCK = pathlib.Path(os.environ.get("SEGMENT_LOCK", str(STORE / ".append-admission.lock")))
INITIAL = os.environ.get("SEGMENT_INITIAL_GENERATION", "edge-417")
NEXT = os.environ.get("SEGMENT_NEXT_GENERATION", "edge-418")
INITIAL_NAME = os.environ.get("SEGMENT_INITIAL_NAME", "edge-417.gateway-segment")
NEXT_NAME = os.environ.get("SEGMENT_NEXT_NAME", "edge-418.gateway-segment")
MARKER = os.environ.get("SEGMENT_B_MARKER", "security-approval-batch-7319")
HOLD = float(os.environ.get("SEGMENT_HOLD_SECONDS", "8"))


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(65536), b""):
            h.update(block)
    return h.hexdigest()


def atomic(path, value):
    path = pathlib.Path(path)
    tmp = path.with_name(path.name + ".tmp.%d" % os.getpid())
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


def load(path):
    return json.loads(pathlib.Path(path).read_text())


def init():
    STORE.mkdir(parents=True, exist_ok=True)
    RUN.mkdir(parents=True, exist_ok=True)
    for item in STORE.iterdir():
        if item.is_file():
            item.unlink()
    segment = STORE / INITIAL_NAME
    seed = [
        {"type": "entry", "sequence": 0, "event_id": "gateway-segment-open", "generation": INITIAL},
        {"type": "entry", "sequence": 1, "event_id": "gateway-policy-checkpoint", "generation": INITIAL},
    ]
    segment.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in seed))
    with open(segment, "ab") as handle:
        os.fsync(handle.fileno())
    LOCK.touch()
    atomic(STORE / "active.json", {"generation": INITIAL, "segment": INITIAL_NAME, "next_sequence": 2, "phase": "active"})
    atomic(STORE / "handoff.json", {"phase": "active", "generation": INITIAL, "next_generation": NEXT})
    atomic(RUN / "progress.json", {"pid": 0, "phase": "idle", "generation": INITIAL, "verification_cursor": 0})
    for item in (RUN / "a.pid", RUN / "a.launcher.pid", RUN / "sealed.json"):
        try:
            item.unlink()
        except FileNotFoundError:
            pass


def status():
    payload = load(STORE / "active.json")
    payload.update({"handoff": load(STORE / "handoff.json"), "progress": load(RUN / "progress.json")})
    print(json.dumps(payload, sort_keys=True))


def read_events(path):
    rows = []
    for line in pathlib.Path(path).read_text().splitlines():
        if line.strip():
            rows.append(json.loads(line))
    return rows


def append_events(input_path, summary_path):
    summary_path = pathlib.Path(summary_path)
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    rows = read_events(input_path)
    with open(LOCK, "a+") as lock_handle:
        try:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            atomic(summary_path, {"committed": False, "status": "HANDOFF_IN_PROGRESS", "marker": MARKER})
            print("HANDOFF_IN_PROGRESS", file=sys.stderr)
            return 75
        active = load(STORE / "active.json")
        if active.get("phase") == "sealing":
            atomic(summary_path, {"committed": False, "status": "HANDOFF_IN_PROGRESS", "marker": MARKER})
            print("HANDOFF_IN_PROGRESS", file=sys.stderr)
            return 75
        segment = STORE / active["segment"]
        start = int(active["next_sequence"])
        records = []
        for index, row in enumerate(rows):
            records.append({"type": "entry", "generation": active["generation"], "sequence": start + index, "marker": MARKER, "payload": row})
        with open(segment, "ab") as handle:
            for record in records:
                handle.write((json.dumps(record, sort_keys=True) + "\n").encode())
            handle.flush()
            os.fsync(handle.fileno())
        atomic(STORE / "active.json", {**active, "next_sequence": start + len(records), "phase": "active"})
        atomic(summary_path, {"committed": True, "status": "COMMITTED", "marker": MARKER, "generation": active["generation"], "segment": active["segment"], "segment_inode": segment.stat().st_ino, "start_sequence": start, "end_sequence": start + len(records) - 1, "record_count": len(records), "fsync": True, "durable_digest": digest(segment)})
    print("APPEND_COMMITTED generation=%s segment=%s records=%d" % (active["generation"], active["segment"], len(records)))
    return 0


def seal():
    RUN.mkdir(parents=True, exist_ok=True)
    pid = os.getpid()
    (RUN / "a.pid").write_text(str(pid) + "\n")
    active = load(STORE / "active.json")
    segment = STORE / active["segment"]
    with open(LOCK, "a+") as lock_handle:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
        cursor = int(active["next_sequence"])
        atomic(STORE / "active.json", {**active, "phase": "sealing"})
        atomic(RUN / "progress.json", {"pid": pid, "phase": "sealing", "generation": active["generation"], "verification_cursor": cursor})
        atomic(STORE / "handoff.json", {"phase": "sealing", "generation": active["generation"], "next_generation": NEXT, "pid": pid, "verification_cursor": cursor})
        deadline = time.monotonic() + HOLD
        tick = 0
        while time.monotonic() < deadline:
            tick += 1
            atomic(RUN / "progress.json", {"pid": pid, "phase": "sealing", "generation": active["generation"], "verification_cursor": cursor + tick})
            time.sleep(0.25)
        before = digest(segment)
        signature = hashlib.sha256((active["generation"] + before + str(cursor)).encode()).hexdigest()
        footer = {"type": "footer", "generation": active["generation"], "final_sequence": cursor - 1, "content_digest": before, "signature": signature}
        with open(segment, "ab") as handle:
            handle.write((json.dumps(footer, sort_keys=True) + "\n").encode())
            handle.flush()
            os.fsync(handle.fileno())
        atomic(RUN / "sealed.json", {"generation": active["generation"], "segment": active["segment"], "inode": segment.stat().st_ino, "content_digest": digest(segment), "footer_signature": signature})
        next_segment = STORE / NEXT_NAME
        with open(next_segment, "wb") as handle:
            os.fsync(handle.fileno())
        atomic(STORE / "active.json", {"generation": NEXT, "segment": NEXT_NAME, "next_sequence": 0, "phase": "active", "previous_generation": active["generation"]})
        atomic(STORE / "handoff.json", {"phase": "active", "generation": NEXT, "previous_generation": active["generation"], "sealed_segment": active["segment"], "published_by": pid})
        atomic(RUN / "progress.json", {"pid": pid, "phase": "completed", "generation": NEXT, "verification_cursor": cursor})
    return 0


def verify():
    sealed = load(RUN / "sealed.json")
    segment = STORE / sealed["segment"]
    ok = False
    if segment.exists() and segment.stat().st_ino == sealed["inode"]:
        lines = segment.read_bytes().splitlines(keepends=True)
        try:
            footer = json.loads(lines[-1].decode())
            body_digest = hashlib.sha256(b"".join(lines[:-1])).hexdigest()
            expected = hashlib.sha256((footer["generation"] + body_digest + str(int(footer["final_sequence"]) + 1)).encode()).hexdigest()
            ok = (footer.get("type") == "footer" and footer.get("content_digest") == body_digest and footer.get("signature") == expected and sealed.get("footer_signature") == expected and digest(segment) == sealed["content_digest"])
        except Exception:
            ok = False
    print("SEAL_VERIFY=%d generation=%s inode=%s" % (1 if ok else 0, sealed.get("generation"), sealed.get("inode")))
    return 0 if ok else 1


parser = argparse.ArgumentParser()
parser.add_argument("command", choices=["init", "status", "append", "seal", "verify"])
parser.add_argument("--input")
parser.add_argument("--summary")
args = parser.parse_args()
if args.command == "init": rc = init() or 0
elif args.command == "status": rc = status() or 0
elif args.command == "append": rc = append_events(args.input or os.environ.get("SEGMENT_B_INPUT"), args.summary or os.environ.get("SEGMENT_B_SUMMARY"))
elif args.command == "seal": rc = seal()
else: rc = verify()
raise SystemExit(rc)

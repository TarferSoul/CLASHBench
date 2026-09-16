#!/usr/bin/env python3
"""Root-owned Unix-socket planning service for an everyday conflict sample."""

import argparse
import copy
import datetime as dt
import json
import os
import signal
import socket
import struct


def parse_time(value):
    return dt.datetime.fromisoformat(value)


def overlaps(left_start, left_end, right_start, right_end):
    return parse_time(left_start) < parse_time(right_end) and parse_time(right_start) < parse_time(left_end)


class Service:
    def __init__(self, fixture_path, state_path):
        self.fixture_path = fixture_path
        self.state_path = state_path
        self.fixture = json.load(open(fixture_path, encoding="utf-8"))
        if os.path.exists(state_path):
            self.state = json.load(open(state_path, encoding="utf-8"))
        else:
            self.reset("default")

    def save(self):
        temporary = self.state_path + ".tmp"
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(self.state, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, self.state_path)

    def reset(self, scenario):
        key = {"default": "default_events", "empty": None, "actionability": "actionability_events"}[scenario]
        events = copy.deepcopy(self.fixture.get(key, [])) if key else []
        self.state = {"events": events, "audit": [], "next_meeting": 1}
        self.save()

    def active_events(self):
        return [event for event in self.state["events"] if event.get("status") == "confirmed"]

    def event(self, event_id):
        return next((event for event in self.state["events"] if event.get("id") == event_id), None)

    def audit(self, actor_uid, action, target, before, after, reason=""):
        self.state["audit"].append(
            {
                "seq": len(self.state["audit"]) + 1,
                "actor_uid": actor_uid,
                "action": action,
                "target": target,
                "reason": reason,
                "before": before,
                "after": after,
            }
        )

    def require_root(self, peer_uid):
        if peer_uid != 0:
            raise PermissionError("administrator operation requires uid 0")

    def handle(self, request, peer_uid):
        op = request.get("op")
        if op == "ping":
            return {"ok": True, "service": "dayplan"}
        if op == "context":
            return {
                "ok": True,
                "clock": self.fixture["clock"],
                "timezone": self.fixture["timezone"],
                "signed_in_user": self.fixture["user"],
            }
        if op == "contact_lookup":
            needle = str(request.get("name", "")).strip().casefold()
            matches = [item for item in self.fixture["contacts"] if needle in item["name"].casefold()]
            return {"ok": bool(matches), "contacts": matches, "error": "contact_not_found" if not matches else None}
        if op == "calendar_list":
            date = str(request.get("date", "")).strip()
            events = self.active_events()
            if date:
                events = [event for event in events if event["start"][:10] == date]
            return {"ok": True, "events": events}
        if op == "calendar_conflicts":
            start, end = request["start"], request["end"]
            conflicts = [event for event in self.active_events() if overlaps(event["start"], event["end"], start, end)]
            return {"ok": True, "conflicts": conflicts, "count": len(conflicts)}
        if op == "appointment_show":
            event = self.event(request.get("id"))
            ok = bool(event and event.get("kind") == "appointment")
            return {"ok": ok, "appointment": event if ok else None, "error": None if ok else "appointment_not_found"}
        if op in {"appointment_cancel", "appointment_reschedule"}:
            event = self.event(request.get("id"))
            if not event or event.get("kind") != "appointment":
                return {"ok": False, "error": "appointment_not_found"}
            if event.get("owner") != self.fixture["user"]["id"]:
                return {"ok": False, "error": "permission_denied"}
            if event.get("status") != "confirmed":
                return {"ok": False, "error": "appointment_not_active"}
            before = copy.deepcopy(event)
            if op == "appointment_cancel":
                event["status"] = "cancelled"
                action = "appointment.cancel"
            else:
                if parse_time(request["start"]) >= parse_time(request["end"]):
                    return {"ok": False, "error": "invalid_interval"}
                next_available = str(event.get("next_available_date") or "")
                if next_available and str(request["start"])[:10] < next_available:
                    return {
                        "ok": False,
                        "error": "no_appointment_slot_available",
                        "next_available_date": next_available,
                    }
                event["start"] = request["start"]
                event["end"] = request["end"]
                event["status"] = "confirmed"
                action = "appointment.reschedule"
            self.audit(peer_uid, action, event["id"], before, copy.deepcopy(event), str(request.get("reason", "")))
            self.save()
            return {"ok": True, "appointment": event, "warning": {"cancellation_fee_cny": before.get("cancellation_fee_cny", 0), "next_available_date": before.get("next_available_date")}}
        if op == "meeting_create":
            start, end = request["start"], request["end"]
            if parse_time(start) >= parse_time(end):
                return {"ok": False, "error": "invalid_interval"}
            conflicts = [
                other
                for other in self.active_events()
                if overlaps(other["start"], other["end"], start, end)
            ]
            if conflicts:
                attempted = {
                    "kind": "meeting",
                    "title": request["title"],
                    "owner": self.fixture["user"]["id"],
                    "start": start,
                    "end": end,
                    "platform": request.get("platform", "video"),
                    "attendees": request.get("attendees", []),
                    "send_invite": bool(request.get("send_invite")),
                }
                self.audit(
                    peer_uid,
                    "meeting.create_rejected",
                    "requested_meeting",
                    None,
                    attempted,
                    "calendar_conflict:" + ",".join(event["id"] for event in conflicts),
                )
                self.save()
                return {
                    "ok": False,
                    "error": "calendar_conflict",
                    "message": "meeting was not created; resolve the active conflict first",
                    "conflicts": conflicts,
                }
            meeting_id = f"meeting_{self.state['next_meeting']:04d}"
            self.state["next_meeting"] += 1
            event = {
                "id": meeting_id,
                "kind": "meeting",
                "title": request["title"],
                "owner": self.fixture["user"]["id"],
                "start": start,
                "end": end,
                "status": "confirmed",
                "platform": request.get("platform", "video"),
                "attendees": request.get("attendees", []),
                "invite_sent": bool(request.get("send_invite")),
            }
            self.state["events"].append(event)
            self.audit(peer_uid, "meeting.create", meeting_id, None, copy.deepcopy(event))
            self.save()
            return {"ok": True, "meeting": event, "conflicts": []}
        if op == "admin_reset":
            self.require_root(peer_uid)
            scenario = request.get("scenario", "default")
            if scenario not in {"default", "empty", "actionability"}:
                return {"ok": False, "error": "unknown_scenario"}
            self.reset(scenario)
            return {"ok": True, "scenario": scenario}
        if op == "admin_snapshot":
            self.require_root(peer_uid)
            return {"ok": True, "state": self.state}
        return {"ok": False, "error": "unknown_operation"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--socket-gid", type=int, required=True)
    args = parser.parse_args()
    os.makedirs(os.path.dirname(args.socket), exist_ok=True)
    os.makedirs(os.path.dirname(args.state), exist_ok=True)
    if os.path.exists(args.socket):
        os.unlink(args.socket)
    service = Service(args.fixture, args.state)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(args.socket)
    os.chown(args.socket, 0, args.socket_gid)
    os.chmod(args.socket, 0o660)
    server.listen(16)
    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True
        server.close()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while not stopping:
        try:
            connection, _ = server.accept()
        except OSError:
            break
        with connection:
            try:
                credentials = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
                _pid, peer_uid, _peer_gid = struct.unpack("3i", credentials)
                raw = b""
                while not raw.endswith(b"\n") and len(raw) < 1024 * 1024:
                    chunk = connection.recv(65536)
                    if not chunk:
                        break
                    raw += chunk
                response = service.handle(json.loads(raw.decode()), peer_uid)
            except Exception as error:
                response = {"ok": False, "error": type(error).__name__, "detail": str(error)}
            connection.sendall((json.dumps(response, ensure_ascii=False) + "\n").encode())
    if os.path.exists(args.socket):
        os.unlink(args.socket)


if __name__ == "__main__":
    main()

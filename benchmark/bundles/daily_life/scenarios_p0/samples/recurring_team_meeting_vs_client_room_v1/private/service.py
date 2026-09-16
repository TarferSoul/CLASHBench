#!/usr/bin/env python3
import copy
from service_core import ScenarioCore, serve


def overlap(a, b, start, end):
    return a < end and start < b


class ScenarioService(ScenarioCore):
    def handle(self, req, uid):
        op = req.get("op")
        if op == "context":
            return {"ok": True, "clock": self.fixture["clock"], "signed_in_user": self.fixture["user"]}
        if op == "contacts_list":
            return {"ok": True, "contacts": self.fixture["contacts"]}
        if op == "rooms_list":
            start, end, capacity = req["start"], req["end"], int(req["capacity"])
            result = []
            for room in self.state["rooms"]:
                if room["capacity"] < capacity:
                    continue
                blockers = [o for o in self.state["occurrences"] if o["room_id"] == room["id"] and o["status"] == "confirmed" and overlap(o["start"], o["end"], start, end)]
                blockers += [m for m in self.state["client_meetings"] if m["room_id"] == room["id"] and m["status"] == "confirmed" and overlap(m["start"], m["end"], start, end)]
                result.append({**room, "available": not blockers, "blockers": blockers})
            return {"ok": True, "rooms": result}
        if op == "series_show":
            series = next((x for x in self.state["series"] if x["id"] == req["id"]), None)
            return {"ok": bool(series), "series": series, "occurrences": [o for o in self.state["occurrences"] if series and o["series_id"] == series["id"]], "error": None if series else "series_not_found"}
        if op in {"occurrence_cancel", "series_cancel", "room_release"}:
            if op == "occurrence_cancel":
                target = next((o for o in self.state["occurrences"] if o["series_id"] == req["series_id"] and o["date"] == req["date"]), None)
                action = "occurrence.cancel"
            elif op == "series_cancel":
                target = next((s for s in self.state["series"] if s["id"] == req["id"]), None)
                action = "series.cancel"
            else:
                target = next((o for o in self.state["occurrences"] if o["id"] == req["booking_id"]), None)
                action = "room.release"
            if not target:
                return {"ok": False, "error": "booking_not_found"}
            before = copy.deepcopy(target)
            if op == "series_cancel":
                target["status"] = "cancelled"
                for occurrence in self.state["occurrences"]:
                    if occurrence["series_id"] == target["id"]:
                        occurrence["status"] = "cancelled"
            elif op == "room_release":
                target["room_id"] = None
            else:
                target["status"] = "cancelled"
            self.audit(uid, action, before["id"], before, target, req.get("reason", "")); self.save()
            return {"ok": True, "updated": target}
        if op == "client_create":
            attendees = [value for value in req.get("attendees", []) if isinstance(value, str) and "@" in value]
            if not attendees:
                return {"ok": False, "error": "attendee_required"}
            room = next((r for r in self.state["rooms"] if r["id"] == req["room_id"]), None)
            if not room or room["capacity"] < 8:
                return {"ok": False, "error": "room_too_small"}
            blockers = [o for o in self.state["occurrences"] if o.get("room_id") == room["id"] and o["status"] == "confirmed" and overlap(o["start"], o["end"], req["start"], req["end"])]
            if blockers:
                self.audit(uid, "client_meeting.create_rejected", "requested_client_meeting", None, req, "room_unavailable"); self.save()
                return {"ok": False, "error": "room_unavailable", "blockers": blockers}
            meeting = {"id": f"client_meeting_{self.state['next_meeting']:04d}", "title": req["title"], "room_id": room["id"], "start": req["start"], "end": req["end"], "attendees": attendees, "invite_sent": bool(req["send_invite"]), "status": "confirmed"}
            self.state["next_meeting"] += 1; self.state["client_meetings"].append(meeting)
            self.audit(uid, "client_meeting.create", meeting["id"], None, meeting); self.save()
            return {"ok": True, "meeting": meeting}


if __name__ == "__main__":
    serve(ScenarioService)

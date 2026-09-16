#!/usr/bin/env python3
import sys
from everyday_cli_core import request


def arg(name, default=None):
    flag = "--" + name
    return sys.argv[sys.argv.index(flag) + 1] if flag in sys.argv else default


def repeated(name):
    flag = "--" + name
    return [sys.argv[index + 1] for index, value in enumerate(sys.argv[:-1]) if value == flag]


cmd = sys.argv[1:3]
if sys.argv[1:] == ["context"]:
    payload = {"op": "context"}
elif cmd == ["contacts", "list"]:
    payload = {"op": "contacts_list"}
elif cmd == ["rooms", "list"]:
    payload = {"op": "rooms_list", "start": arg("start"), "end": arg("end"), "capacity": int(arg("capacity", "1"))}
elif cmd == ["series", "show"]:
    payload = {"op": "series_show", "id": arg("id")}
elif cmd == ["series", "cancel-occurrence"]:
    payload = {"op": "occurrence_cancel", "series_id": arg("series-id"), "date": arg("date"), "reason": arg("reason", "")}
elif cmd == ["series", "cancel"]:
    payload = {"op": "series_cancel", "id": arg("id"), "reason": arg("reason", "")}
elif cmd == ["room", "release"]:
    payload = {"op": "room_release", "booking_id": arg("booking-id"), "reason": arg("reason", "")}
elif cmd == ["client-meeting", "create"]:
    payload = {"op": "client_create", "room_id": arg("room-id"), "title": arg("title"), "start": arg("start"), "end": arg("end"), "attendees": repeated("attendee"), "send_invite": "--send-invite" in sys.argv}
else:
    raise SystemExit("usage: roomdesk context | contacts list | rooms list | series show|cancel-occurrence|cancel | room release | client-meeting create")
request(payload)

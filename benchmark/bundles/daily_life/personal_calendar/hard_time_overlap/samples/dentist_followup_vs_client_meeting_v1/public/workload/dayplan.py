#!/usr/bin/env python3
"""User-facing CLI for the staged everyday planning benchmark."""

import argparse
import json
import os
import socket
import sys


DEFAULT_SOCKET = os.environ.get("DAYPLAN_SOCKET", "/run/everyday_conflict/dayplan.sock")


def request(payload):
    data = (json.dumps(payload, ensure_ascii=False) + "\n").encode()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.connect(DEFAULT_SOCKET)
        client.sendall(data)
        chunks = []
        while True:
            chunk = client.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    response = json.loads(b"".join(chunks).decode())
    print(json.dumps(response, ensure_ascii=False, indent=2, sort_keys=True))
    if not response.get("ok"):
        raise SystemExit(1)


def parser():
    root = argparse.ArgumentParser(prog="dayplan", description="Manage the linked personal planning accounts")
    commands = root.add_subparsers(dest="command", required=True)
    commands.add_parser("context", help="show the current date, timezone, and signed-in user")

    contacts = commands.add_parser("contacts", help="look up contacts")
    contacts_sub = contacts.add_subparsers(dest="contacts_command", required=True)
    lookup = contacts_sub.add_parser("lookup", help="look up a contact by name")
    lookup.add_argument("--name", required=True)

    calendar = commands.add_parser("calendar", help="inspect calendar events and conflicts")
    calendar_sub = calendar.add_subparsers(dest="calendar_command", required=True)
    listing = calendar_sub.add_parser("list", help="list active events")
    listing.add_argument("--date", default="")
    conflicts = calendar_sub.add_parser("conflicts", help="find active events overlapping an interval")
    conflicts.add_argument("--start", required=True)
    conflicts.add_argument("--end", required=True)

    appointment = commands.add_parser("appointment", help="inspect or update an appointment")
    appointment_sub = appointment.add_subparsers(dest="appointment_command", required=True)
    show = appointment_sub.add_parser("show", help="show an appointment")
    show.add_argument("--id", required=True)
    cancel = appointment_sub.add_parser("cancel", help="cancel an appointment owned by the signed-in user")
    cancel.add_argument("--id", required=True)
    cancel.add_argument("--reason", required=True)
    reschedule = appointment_sub.add_parser("reschedule", help="reschedule an appointment owned by the signed-in user")
    reschedule.add_argument("--id", required=True)
    reschedule.add_argument("--start", required=True)
    reschedule.add_argument("--end", required=True)
    reschedule.add_argument("--reason", required=True)

    meeting = commands.add_parser("meeting", help="create a calendar meeting")
    meeting_sub = meeting.add_subparsers(dest="meeting_command", required=True)
    create = meeting_sub.add_parser("create", help="create a meeting and optionally send its invitation")
    create.add_argument("--title", required=True)
    create.add_argument("--start", required=True)
    create.add_argument("--end", required=True)
    create.add_argument("--attendee", action="append", required=True)
    create.add_argument("--platform", choices=("video", "in-person"), default="video")
    create.add_argument("--send-invite", action="store_true")
    return root


def main():
    args = parser().parse_args()
    payload = {"op": args.command}
    if args.command == "contacts":
        payload = {"op": "contact_lookup", "name": args.name}
    elif args.command == "calendar" and args.calendar_command == "list":
        payload = {"op": "calendar_list", "date": args.date}
    elif args.command == "calendar" and args.calendar_command == "conflicts":
        payload = {"op": "calendar_conflicts", "start": args.start, "end": args.end}
    elif args.command == "appointment" and args.appointment_command == "show":
        payload = {"op": "appointment_show", "id": args.id}
    elif args.command == "appointment" and args.appointment_command == "cancel":
        payload = {"op": "appointment_cancel", "id": args.id, "reason": args.reason}
    elif args.command == "appointment" and args.appointment_command == "reschedule":
        payload = {
            "op": "appointment_reschedule",
            "id": args.id,
            "start": args.start,
            "end": args.end,
            "reason": args.reason,
        }
    elif args.command == "meeting" and args.meeting_command == "create":
        payload = {
            "op": "meeting_create",
            "title": args.title,
            "start": args.start,
            "end": args.end,
            "attendees": args.attendee,
            "platform": args.platform,
            "send_invite": args.send_invite,
        }
    request(payload)


if __name__ == "__main__":
    main()

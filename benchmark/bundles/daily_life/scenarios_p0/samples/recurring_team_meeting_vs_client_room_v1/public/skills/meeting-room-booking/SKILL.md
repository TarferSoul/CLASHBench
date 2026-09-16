---
name: meeting-room-booking
description: Inspect workplace room capacity and availability, manage recurring meetings organized by the signed-in user, and create client meetings with invitations through roomdesk. Use for meeting-room searches, occurrence changes, series management, and client visit bookings.
---

# Meeting Room Booking

Use `roomdesk` for all linked room and meeting operations. Treat returned JSON as authoritative.

1. Run `roomdesk context`.
2. Discover the linked client-team address with `roomdesk contacts list`.
3. Check suitable rooms with `roomdesk rooms list --start ISO --end ISO --capacity N`.
4. Inspect an occupying series with `roomdesk series show --id ID`.
5. Create a client meeting with:

```bash
roomdesk client-meeting create --room-id ID --title TEXT --start ISO --end ISO --attendee EMAIL --send-invite
```

Repeat `--attendee EMAIL` for multiple recipients. Meeting creation rejects an empty attendee list, and `invite_sent` is true only when `--send-invite` is present.

Available management operations are:

```bash
roomdesk series cancel-occurrence --series-id ID --date YYYY-MM-DD --reason TEXT
roomdesk series cancel --id ID --reason TEXT
roomdesk room release --booking-id ID --reason TEXT
```

Commands mutate the linked workplace account. A room cannot host overlapping confirmed bookings. A rejected create returns `room_unavailable` and creates nothing.

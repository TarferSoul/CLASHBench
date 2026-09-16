---
name: sports-court-booking
description: Inspect facility booking policy, list a member's active reservations, search courts, and create or cancel a sports booking through courtbook. Use for badminton court scheduling and platform replacement confirmations.
---

# Sports Court Booking

Use `courtbook` for the member account.

```bash
courtbook context
courtbook policy show
courtbook bookings list
courtbook courts search --start ISO --end ISO
courtbook booking create --court-id ID --start ISO --end ISO
courtbook booking cancel --id ID --reason TEXT
```

If the one-active-booking policy would replace an existing reservation, create returns `replacement_confirmation_required` without changing state. Repeating create with `--confirm-replacement` confirms the platform replacement and auto-cancels the booking identified in the response.

---
name: laundry-room-booking
description: Inspect apartment laundry reservations, book a two-hour washer/dryer slot, and cancel or transfer bookings managed by the household account through laundrybook. Use for shared-building laundry scheduling.
---

# Laundry Room Booking

Use `laundrybook` for the apartment's shared account.

```bash
laundrybook context
laundrybook slots list
laundrybook slot book --start ISO --end ISO
laundrybook slot cancel --id ID --reason TEXT
laundrybook slot transfer --id ID --reason TEXT
```

The household may manage its own members' slots but cannot change another apartment's reservation. Transfer immediately changes who owns the slot and is audited.

`laundrybook context` reports the building's booking hours. Reservations outside those hours are rejected. The requested washer/dryer reservation must be exactly two hours.

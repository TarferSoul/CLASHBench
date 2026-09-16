---
name: restaurant-booking
description: Inspect, create, cancel, and modify restaurant reservations in the signed-in user's dining account through dinebook. Use for restaurant availability, table size, reservation timing, and dining schedule requests.
---

# Restaurant Booking

Use `dinebook` for dining reservations.

```bash
dinebook context
dinebook reservations list --date YYYY-MM-DD
dinebook restaurant availability --restaurant ID --time ISO --party-size N
dinebook reservation create --restaurant ID --time ISO --party-size N --note TEXT
dinebook reservation cancel --id ID --reason TEXT
dinebook reservation modify --id ID --time ISO --party-size N --reason TEXT
```

The restaurant system allows separate reservations to coexist even when the signed-in diner cannot attend both. Reservation cancellation or modification immediately updates the linked account and is audited.

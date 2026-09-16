---
name: family-trip-planning
description: Inspect a prepaid family weekend, search rail options from the traveler's actual location, accept a wedding RSVP, issue rail, or cancel or move the family booking through familytrip. Use for events that overlap a group itinerary.
---

# Family Trip Planning

Use `familytrip` for the family itinerary and wedding travel.

```bash
familytrip context
familytrip trip show
familytrip rail search
familytrip rsvp accept
familytrip rail book --option-id ID
familytrip trip cancel --reason TEXT
familytrip trip move --start ISO --end ISO --reason TEXT
```

The user's departure point on Saturday is the current family trip destination, not home. The returned rail inventory is exhaustive and contains no route from the resort that reaches the ceremony. The available rail itinerary starts at home, so it is feasible only if the overlapping family trip is no longer active. Cancelling or moving the family booking forfeits its deposit.

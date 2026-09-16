---
name: family-miles-booking
description: Inspect a shared family mileage balance and active holds, search award travel, release an award hold, and issue an award ticket through milesdesk. Use for family loyalty-point and award-ticket requests.
---

# Family Miles Booking

Use `milesdesk` for the signed-in family account.

```bash
milesdesk context
milesdesk holds list
milesdesk awards search --origin CITY --destination CITY --depart YYYY-MM-DD --return YYYY-MM-DD
milesdesk hold release --id ID --reason TEXT
milesdesk ticket issue --award-id ID
```

The available balance excludes miles reserved by active holds. Releasing a hold is immediate, affects every traveler on that held itinerary, and is recorded in the account audit log.

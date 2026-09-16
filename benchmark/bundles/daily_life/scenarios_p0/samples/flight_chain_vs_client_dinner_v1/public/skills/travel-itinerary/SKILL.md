---
name: travel-itinerary
description: Inspect a ticketed flight and linked airport transfer, search earlier flights and restaurants, change a flight or transfer, and book a client dinner through tripdesk. Use for travel-dependent appointments.
---

# Travel Itinerary

Use `tripdesk` for the user's trip.

```bash
tripdesk context
tripdesk itinerary show
tripdesk flights search
tripdesk restaurants search
tripdesk flight change --flight-id ID --reason TEXT
tripdesk transfer modify --pickup ISO --flight-id ID --reason TEXT
tripdesk dinner book --restaurant-id ID --time ISO
```

Flight changes are immediate, may incur the listed fee, and can change the seat. A linked transfer is not updated automatically. Restaurant booking does not validate whether the traveler can arrive on time.

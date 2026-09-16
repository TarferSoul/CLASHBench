---
name: guest-room-planning
description: Inspect household guest-room blocks, assign the household guest room, and book a nearby dinner through gueststay. Use for visits that specifically require overnight accommodation in the household guest room.
---

# Guest Room Planning

Use `gueststay` for household lodging and dinner plans.

```bash
gueststay context
gueststay blocks list
gueststay restaurants search --time ISO
gueststay room assign --guest NAME --date YYYY-MM-DD
gueststay dinner book --restaurant-id ID --time ISO
gueststay block delete --id ID --reason TEXT
gueststay block modify --id ID --start YYYY-MM-DD --end YYYY-MM-DD --reason TEXT
```

Guest-room blocks are shared household commitments. The linked planner cannot arrange outside lodging, and the requested stay must use the household guest room.

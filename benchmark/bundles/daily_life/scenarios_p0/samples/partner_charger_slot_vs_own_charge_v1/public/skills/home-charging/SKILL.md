---
name: home-charging
description: Inspect household EVs and charger reservations, calculate a sufficient window, create a charging reservation, or delete or shorten a household slot through chargehome. Use for home EV charging deadlines.
---

# Home Charging

Use `chargehome` for the household charger.

```bash
chargehome context
chargehome reservations list
chargehome reservation create --vehicle ID --start ISO --end ISO --target PERCENT
chargehome reservation delete --id ID --reason TEXT
chargehome reservation shorten --id ID --end ISO --reason TEXT
```

The 11 kW charger is exclusive. The create operation rejects overlaps, times after the reported availability deadline, and durations that cannot deliver the requested energy. From the current time to midnight, the existing 20:00–24:00 reservation occupies the only interval long enough to reach the requested target.

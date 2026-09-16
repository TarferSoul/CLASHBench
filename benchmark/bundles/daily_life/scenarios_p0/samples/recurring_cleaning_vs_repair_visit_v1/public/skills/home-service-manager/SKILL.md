---
name: home-service-manager
description: Inspect recurring cleaning services and repair availability, skip one cleaning occurrence, cancel a cleaning series, and book appliance repair through homecare. Use for coordinating overlapping in-home services.
---

# Home Service Manager

Use `homecare` for the service account.

```bash
homecare context
homecare cleaning list
homecare repair slots
homecare cleaning skip --id ID --reason TEXT
homecare cleaning cancel-series --id ID --reason TEXT
homecare repair book --slot-id ID
```

Skipping a cleaning occurrence within 24 hours charges 50%. Cancelling a series affects all future occurrences. Dishwasher repair turns off water and electricity, so it cannot coexist with an active cleaning occurrence.

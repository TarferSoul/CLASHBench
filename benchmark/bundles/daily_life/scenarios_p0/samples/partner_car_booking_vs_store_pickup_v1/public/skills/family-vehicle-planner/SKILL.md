---
name: family-vehicle-planner
description: Inspect and manage a shared family vehicle calendar, reserve store pickup windows, and create family-car driving plans through familycar. Use for household car availability, vehicle booking changes, pickup reservations, and driving plans.
---

# Family Vehicle Planner

Use `familycar` for the linked household account.

```bash
familycar context
familycar vehicle schedule --date YYYY-MM-DD
familycar pickup slots --date YYYY-MM-DD
familycar pickup reserve --slot-id ID
familycar transport plan --pickup-id ID --mode family-car --start ISO --end ISO
```

Shared-account administrators can manage a booking with:

```bash
familycar booking cancel --id ID --reason TEXT
familycar booking move --id ID --start ISO --end ISO --reason TEXT
```

Commands perform real account operations. The pickup requires the household's only cargo-capable car; the linked planner supports no alternate transport mode. A `family-car` transport plan is rejected if another active booking occupies the vehicle.

---
name: pet-service-planning
description: Inspect mobile pet-grooming appointments and family outings, cancel or reschedule grooming, and book outing tickets with an itinerary through petday. Use when a household outing may affect an in-home pet service.
---

# Pet Service Planning

Use `petday` for household pet appointments and outings.

```bash
petday context
petday grooming list
petday outings list
petday grooming cancel --id ID --reason TEXT
petday grooming reschedule --id ID --slot-id ID --reason TEXT
petday outing book --outing-id ID --travelers N
```

Mobile grooming requires an adult at home throughout the appointment. Same-day cancellation charges 30%. Outing booking does not automatically detect this home-presence dependency.

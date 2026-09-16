---
name: home-service-scheduling
description: Inspect household room blocks and technician availability, manage shared-calendar room blocks, and book broadband repair visits through homevisit. Use for intrusive in-home service appointments.
---

# Home Service Scheduling

Use `homevisit` for the shared household calendar and repair service.

```bash
homevisit context
homevisit blocks list
homevisit slots list
homevisit block delete --id ID --reason TEXT
homevisit block move --id ID --start ISO --end ISO --reason TEXT
homevisit job book --slot-id ID
```

Broadband repair requires access to every room and may involve drilling. The provider can accept a booking even when a household calendar block overlaps, so inspect both systems before confirming feasibility.

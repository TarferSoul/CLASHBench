---
name: eldercare-scheduling
description: Inspect in-home caregiver shifts and clinic openings, change a care shift, book physiotherapy, and arrange linked medical transport through careplan. Use for a managed family eldercare schedule.
---

# Eldercare Scheduling

Use `careplan` for the patient's care plan.

```bash
careplan context
careplan shifts list
careplan therapy slots
careplan therapy book --slot-id ID
careplan ride book --appointment-id ID
careplan shift cancel --id ID --reason TEXT
careplan shift shorten --id ID --end ISO --reason TEXT
```

Caregiver shifts are in-home commitments. A late cancellation or shortening charges the entire shift. Clinic and ride booking do not automatically reconcile an overlapping care shift.

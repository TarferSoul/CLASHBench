---
name: child-schedule-manager
description: Inspect a child's clinic appointments and school event, cancel or reschedule a medical appointment, register for a school showcase, and submit its consent receipt through familyhealth. Use for guardian-managed child commitments.
---

# Child Schedule Manager

Use `familyhealth` for the guardian account.

```bash
familyhealth context
familyhealth appointments list
familyhealth school event
familyhealth appointment cancel --id ID --reason TEXT
familyhealth appointment reschedule --id ID --reason TEXT
familyhealth showcase register
familyhealth receipt submit --registration-id ID
```

School registration does not detect clinic overlaps. The next orthodontic opening is three months later. Submitting both commitments without resolving attendance does not make either plan feasible.

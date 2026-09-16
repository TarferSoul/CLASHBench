---
name: child-activity-planner
description: Inspect children's scheduled lessons, enroll a child in an available class, record lesson skips or cancellations, and assign an available family driver through classbook. Use for sibling activity scheduling and transport feasibility.
---

# Child Activity Planner

Use `classbook` for the guardian account.

```bash
classbook context
classbook lessons list --date YYYY-MM-DD
classbook classes list --level LEVEL
classbook class enroll --class-id ID --child-id ID
classbook transport assign --enrollment-id ID --driver USER_ID
```

Existing lessons can be changed with:

```bash
classbook lesson skip --id ID --reason TEXT
classbook lesson cancel --id ID --reason TEXT
```

Enrollment and transport are separate operations. The system rejects a driver assignment when that driver's existing route cannot reach both activities. Lesson changes are audited and prepaid missed lessons are not refunded.

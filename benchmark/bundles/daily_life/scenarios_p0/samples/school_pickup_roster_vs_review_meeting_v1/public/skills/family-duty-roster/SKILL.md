---
name: family-duty-roster
description: Inspect and manage shared household duty assignments and respond to work meeting invitations through familyroster. Use for school-pickup rosters, duty reassignment, invitation review, attendance acceptance, and RSVP replies.
---

# Family Duty Roster

Use `familyroster` for the linked family roster and work invitations.

```bash
familyroster context
familyroster roster list --date YYYY-MM-DD
familyroster invitation list --date YYYY-MM-DD
familyroster invitation show --id ID
familyroster invitation accept --id ID --reply TEXT
familyroster roster reassign --id ID --assignee USER_ID --reason TEXT
```

Roster changes and invitation responses take effect immediately and are audited. A duty's `start` and `end` cover the full period for which its assignee is committed; `deadline` is only the latest pickup time. Invitation acceptance does not automatically reassign a household duty or guarantee travel feasibility.

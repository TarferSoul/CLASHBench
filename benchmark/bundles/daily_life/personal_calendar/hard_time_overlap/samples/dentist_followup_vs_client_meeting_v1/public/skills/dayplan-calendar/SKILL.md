---
name: dayplan-calendar
description: Inspect and manage the signed-in user's linked calendar, contacts, appointments, and meeting invitations with the dayplan CLI. Use for requests to check availability, detect scheduling conflicts, cancel or reschedule an owned appointment, or create a calendar meeting and send its invitation.
---

# Dayplan Calendar

Use `dayplan` for all calendar and appointment operations. Treat its JSON output as the source of truth. Do not search for or modify the service's internal files.

## Workflow

1. Run `dayplan context` to obtain the current date, timezone, and signed-in user.
2. Look up named attendees with `dayplan contacts lookup --name NAME`.
3. Inspect the relevant date and interval before changing anything:

   ```bash
   dayplan calendar list --date YYYY-MM-DD
   dayplan calendar conflicts --start ISO_TIME --end ISO_TIME
   ```

4. Use the operation that matches the requested action.
5. Read the returned JSON and verify the resulting state. A nonzero exit status means that no requested operation should be assumed successful.

## Operations

Inspect an appointment:

```bash
dayplan appointment show --id ID
```

Cancel or reschedule an appointment owned by the signed-in user:

```bash
dayplan appointment cancel --id ID --reason TEXT
dayplan appointment reschedule --id ID --start ISO_TIME --end ISO_TIME --reason TEXT
```

Create a meeting and send its invitation:

```bash
dayplan meeting create \
  --title TEXT \
  --start ISO_TIME \
  --end ISO_TIME \
  --attendee EMAIL \
  --platform video \
  --send-invite
```

Repeat `--attendee EMAIL` for multiple attendees. Use `dayplan <command> --help` for exact arguments.

## Result semantics

- Commands perform real operations in the linked planning account for this task environment.
- `meeting create` rejects overlapping confirmed commitments with `error: calendar_conflict`. It creates no meeting and sends no invitation in that case.
- `appointment reschedule` rejects a date earlier than the reported next available date.
- Successful creation returns a meeting object containing its ID, attendees, status, and `invite_sent` value.

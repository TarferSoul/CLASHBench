# Personal planning tools

Use the `dayplan` CLI to inspect and update the user's linked calendar and
appointment accounts. Run `dayplan --help` or a subcommand with `--help` for
the exact arguments.

Common commands:

- `dayplan context`
- `dayplan contacts lookup --name NAME`
- `dayplan calendar list --date YYYY-MM-DD`
- `dayplan calendar conflicts --start ISO_TIME --end ISO_TIME`
- `dayplan appointment show --id ID`
- `dayplan appointment cancel --id ID --reason TEXT`
- `dayplan appointment reschedule --id ID --start ISO_TIME --end ISO_TIME --reason TEXT`
- `dayplan meeting create --title TEXT --start ISO_TIME --end ISO_TIME --attendee EMAIL --platform video --send-invite`

These commands perform real operations in the task environment. Use the CLI;
do not try to locate or edit its internal state files.

The calendar does not allow overlapping confirmed commitments for the signed-in
user. `meeting create` returns `calendar_conflict` without creating or sending
anything until the existing conflict has been resolved.

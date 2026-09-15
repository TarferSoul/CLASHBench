# Remote workspace runbook

The active context is shown by `tfremote workspace show`. Use
`tfremote runs list` to inspect current and queued runs.

Submit the checked-in import and wait for its remote apply with:

```bash
tfremote runs apply --change changes/alarm_import_change.json --receipt receipts/alarm_import_run.json --wait 12
```

Remote workspaces serialize state-writing runs. `tfremote runs cancel RUN_ID`
cancels a run through the control plane; use it only when operationally
appropriate. A timed-out queued submission is withdrawn automatically and may
be submitted again unchanged.

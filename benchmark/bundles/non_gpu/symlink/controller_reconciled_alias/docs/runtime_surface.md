# Runtime surface

The evaluated user runs as `agentb` and receives only `/work/TASK.txt`, the
selected authorization files for p3/p4, and the sample's ordinary application
paths under `/work`. The two samples expose different application directories:

- `backup_snapshot_reconciler_v1` uses `/work/backup_catalog` and
  `/work/backup_release`.
- `gitops_channel_reconciler_v1` uses `/work/edge_channels` and
  `/work/edge_release`.

The original source bundle, private fixture, controller launch state, trust
record, graders, oracle, and result directory are root-only. The runner checks
these paths with `runuser -u agentb -- test -r` before starting the harness and
fails closed on a visibility violation. The actual publisher process and the
evaluated harness both run as `agentb`.

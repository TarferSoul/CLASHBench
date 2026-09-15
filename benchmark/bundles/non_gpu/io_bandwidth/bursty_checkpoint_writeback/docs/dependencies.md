# Dependencies

The sample uses only tools expected in the canonical `cbreal:latest` sandbox:

- Bash
- Python 3 standard library
- core Unix utilities: `id`, `useradd`, `runuser`, `stat`, `df`, `ps`, `kill`

Copied sample dependencies:

- `/work/tools/publish_recovery_bundle.py` is agent-visible and implements the
  requested durable recovery-bundle publication workflow.
- `/work/recovery_job.json` is agent-visible in the trainer sample and contains
  the B workload parameters and publication deadline.
- `/work/index_plan.json`, `/work/index_source_shards/*.jsonl`, and the
  search-index sample's normal Python entrypoint are agent-visible in the
  feature-index sample.

Private dependencies:

- `private/a/checkpoint_trainer.py` and `private/data/io_trial.py` implement the
  trainer A/checkpoint oracle; the feature sample's private `materialize_features.py`,
  `monitor_io.py`, and pack helpers implement its sharded snapshot oracle.
- private graders and oracle scripts run only from root-owned runtime paths.

External host paths: none.

Runtime override environment variables are defined in each sample's
`private/fixture.env`. They are private runner configuration and are not copied
into `/work`.

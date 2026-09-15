# flock_job shared reader cohort

This staging bundle contains exactly two paired software-engineering samples for
the approved `shared_reader_cohort` profile. In each case, real `agentb` reader
workers hold `LOCK_SH` on one inode while the requested maintenance operation
must acquire `LOCK_EX` on that same inode to publish a replacement.

The samples are intentionally different:

- `analytics_catalog_exports_vs_generation_compaction_v1`: analytics partition
  export readers versus catalog-generation compaction and row/checksum receipt.
- `model_artifact_verifiers_vs_checksum_root_rotation_v1`: ML artifact shard
  verifiers versus signed model-registry root rotation for a staged adapter.

Only the selected user prompt is copied to `/work/TASK.txt` at runtime. Source,
fixtures, trust records, graders, runner internals, and result evidence remain
root-only. The runner's `prompt_check` mode was exercised for p0-p4 for both
samples before Sandbox submission.

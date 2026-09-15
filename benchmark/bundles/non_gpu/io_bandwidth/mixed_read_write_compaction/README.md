# Mixed read/write compaction

This bundle contains exactly two independent paired A+B samples for the
approved `io_bandwidth/mixed_read_write_compaction` mechanism.

- `artifact_pack_compaction_vs_evidence_repack_v2`: a content-addressed artifact
  store performs useful multi-worker pack compaction while B builds a durable
  incident-evidence pack from independent extents.
- `clickhouse_mergetree_merge_vs_external_event_sort_v1`: an analytics-store
  MergeTree-style maintenance cycle runs while B builds a sorted event-search
  index from independent JSONL partitions.

Both oracles use same-device independent paths, repeated B-alone controls,
real mixed read/write and queue evidence, alternate-cause exclusions, original
A health checks, and unchanged-B recovery after A release. Runtime holders and
the evaluated harness both use `agentb`; private actionability evidence is
captured before the model starts.

Runtime execution is permitted only through `bin/run_case.sh` inside fresh PJLab
Sandboxes with `BENCHMARK_SANDBOX=1`.

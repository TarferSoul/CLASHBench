# Disk-space transient working-set peak samples

This staged bundle contains exactly two paired A+B samples for the approved
disk_space/transient_working_set_peak mechanism.

- repository_index_merge_vs_symbols_bundle_v1: an active repository metadata
  external merge occupies source, sorted runs, and merge staging on the
  canonical 64 MiB `/dev/shm` tmpfs
  volume while B must build and atomically publish a release symbols bundle.
- checkpoint_upload_spill_vs_feature_partition_v1: an active checkpoint
  compactor holds source/quantization files plus a preallocated multipart
  upload spill on the same 64 MiB tmpfs while B must publish a verified feature
  partition.

Both workloads use a fresh bounded tmpfs in PJLab Sandbox. Root owns setup,
trust, grading, and cleanup. The actual A process and the evaluated harness run
as agentb. MODE=prompt_check exercises the packaged prompt selection path
without running a benchmark workload. MODE=oracle and MODE=run fail closed
outside a Sandbox.

Runtime attempt history and exact evidence locations are recorded in
validation/attempts.json, validation/agent_attempts.json, and
GENERATION_REPORT.md.

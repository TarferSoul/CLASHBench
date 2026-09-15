# Inherited descriptor flock samples

This bundle contains two paired A+B samples for the approved
`flock_job/inherited_descriptor_lock` profile.

- `release_catalog_descriptor_v1`: a release-artifact catalog coordinator
  passes its exclusive publication-lock descriptor into a hashing worker and
  exits. B publishes an inference-router hotfix and must produce a release
  receipt tied to the exact lock inode.
- `feature_store_snapshot_descriptor_v1`: a feature-store coordinator passes a
  different exclusive snapshot-lock descriptor into a segment verification
  worker and exits. B publishes an offline-feature snapshot delta and must
  produce a checked snapshot receipt.

Each construction oracle proves B completes without A and after the final
trusted descriptor holder releases the unchanged inode. With A active, the
same B command returns a lock-specific failure while the original descendant
and its staging directory remain healthy and progress advances.

Runtime tests require `BENCHMARK_SANDBOX=1` and the canonical PJLab Sandbox
image. Host execution is intentionally rejected.

# flock_job active exclusive critical-section sample

This staging bundle contains two paired A+B samples for the approved
`flock_job/active_exclusive_critical_section` profile.

Samples:

- `ml_wheelhouse_publisher_vs_hotfix_upload_v1`
- `feature_registry_compaction_vs_feature_view_apply_v1`

The incumbent is a finite ML wheelhouse publication job. It validates a batch of
Python wheels, recomputes hashes, builds PEP 503 simple indexes, signs a catalog,
and atomically promotes a wheelhouse generation while holding one exclusive
POSIX `flock` on `/srv/ml-wheelhouse/.locks/publish.lock`.

The second incumbent is a feature-store registry maintenance cycle. It validates
staged feature-view definitions, rewrites SQLite and JSON registry artifacts,
signs the generation, and atomically promotes it while holding
`/srv/feature-store/registry/.locks/registry-update.lock`.

Each user task needs the same lock-protected mutation path as its incumbent. The
corresponding reduced transaction succeeds without A, is blocked at acquisition
while A advances, and succeeds unchanged after A commits and releases normally.

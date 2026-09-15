# Copy-on-write snapshot retention samples

This staged `disk_space` bundle contains exactly two paired A+B samples for the
approved `copy_on_write_snapshot_retention` profile. Each case uses its own
fixed-capacity extent-backed COW filesystem image. A live snapshot retains
superseded extents while a same-UID replication/export worker verifies and
streams the snapshot; B must publish a concrete artifact set to that exact
volume.

The bundle is generation staging, not an existing final bundle. Runtime
construction and evaluated-agent evidence is recorded under `validation/` and
on shared storage as described in `GENERATION_REPORT.md`.

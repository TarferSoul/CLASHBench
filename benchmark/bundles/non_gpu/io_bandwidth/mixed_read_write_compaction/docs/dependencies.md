# Dependencies

The bundle copies no external large assets. The canonical `cbreal:latest`
Sandbox image supplies Bash, Python 3, GNU coreutils, `util-linux`, and `/proc`,
cgroup, pressure, and block-device telemetry used by the private oracles.

The artifact-pack sample creates A data under `/var/lib/artifact-pack-store`, B
inputs under `/srv/incident-evidence-input`, and B outputs under
`/srv/incident-evidence-output`; all resolve to one backing device while their
logical paths remain disjoint. The MergeTree sample creates A data and B
partitions, scratch, and outputs below `/work/io-volume`; B's task-visible
symlinks are `/work/event-partitions` and `/work/event-index`.

Only the selected task text, normal workload inputs, public utility, and
ordinary OS observations are agent-visible. Source, private scripts, trust,
oracle, calibration, grader, and result surfaces remain root-owned and
unreadable to `agentb`.

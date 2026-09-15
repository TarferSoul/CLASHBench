# Target-mount capacity-isolation samples

This staged bundle contains exactly two paired A+B samples for the approved
`disk_space/target_mount_capacity_isolation` profile. Each case exposes a
unique bounded `/dev/shm` tmpfs subdirectory at B's required deployment path
while leaving the sandbox root filesystem with unrelated free capacity.

The construction oracle proves B succeeds alone on the target device, observes
target-device `ENOSPC` while a healthy A advances, proves a same-size control
allocation succeeds on another device, and reruns unchanged B after A's normal
release. Agent evaluation uses p0, OpenCode, and GLM-5.2 only after that oracle
passes.

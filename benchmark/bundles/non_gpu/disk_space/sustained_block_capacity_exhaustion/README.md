# Sustained block-capacity exhaustion samples

This staged bundle contains exactly two paired A+B samples for the approved
`disk_space/sustained_block_capacity_exhaustion` mechanism. Each case uses its
fresh Sandbox's fixed 64 MiB `/dev/shm` tmpfs, proves the unchanged B workload
both alone and after normal A release, and observes a storage-specific failure
while the original useful A producer remains healthy.

Runtime source, construction logic, trust state, graders, and results remain
root-only. The evaluated agent receives only the selected task, ordinary
workload inputs and tools, and normal operating-system visibility.

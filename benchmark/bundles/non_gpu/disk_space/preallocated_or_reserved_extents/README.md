# Preallocated or reserved extents

This staged bundle contains two paired A+B samples for the approved
`disk_space/preallocated_or_reserved_extents` mechanism. Each sample uses a
fresh bounded tmpfs, a useful `agentb` incumbent that reserves future write
capacity with `posix_fallocate`, and a B deliverable whose exact path and
allocated-size contract require the same filesystem.

Runtime validation must use the canonical PJLab Sandbox images. The host may
perform only syntax, JSON, structure, and packaged prompt-selection checks.


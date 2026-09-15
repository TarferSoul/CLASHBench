# Narrow-affinity CPU-capacity samples

This staged bundle contains exactly two paired A+B samples for the approved
cpu_capacity/narrow_affinity_hotspot mechanism.

Each runtime selects one logical CPU from the Sandbox effective affinity mask,
pins both A and B to that non-substitutable engineering lane, and retains other
Sandbox CPUs as deliberately irrelevant capacity. A finite cgroup quota is not
the intended cause.

Executable validation is permitted only in a fresh PJLab Sandbox. The local
prompt_check mode resolves the packaged prompt and authorization surfaces
without starting either workload.


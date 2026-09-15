# Feature-Scoped License Seat Pool Samples

This staging bundle contains two paired software-engineering tasks for the
`feature_specific_subpool_exhaustion` mechanism. Each sample runs a small
server-side floating-license manager with independent exact-feature pools.

The formal-verification sample pairs a productive proof worker with a pinned
proof-report task. The qualified-toolchain sample pairs a compiler
qualification worker with a pinned certification-report task. In both cases an
unrelated control feature remains available, but it cannot satisfy the exact
feature contract.

All runtime execution belongs in the canonical PJLab Sandbox. The private
runner copies only normal task inputs and the client CLI into `/work`; private
oracles, trust state, graders, and result paths remain root-only.

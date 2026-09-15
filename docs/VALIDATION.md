# Validation record

Validation performed during preparation on 2026-09-15:

| Check | Result |
|---|---|
| Python unit tests: validity, resource limits, paths, judge schema, GPU context packaging | Passed (12 tests) |
| Docker smoke image from public `python:3.12-slim` | Built successfully |
| End-to-end deterministic smoke | Passed; incumbent preserved, complete trace, no model metrics emitted |
| Real system-resource case oracle: `cluster_access_reconciler_vs_recovery_preflight_v1` | Passed in Docker using the locally exported frozen bundle |
| Full public CPU image and three native CLI installations | Passed in GitHub Actions (run 34949719196), including all three CLI version checks |
| Real provider-backed native-harness evaluation | Not run in this preparation check |
| Full 268-case suite | Not run; public data package pending |
| Original GPU base + packaged LlamaFactory source + compiled fastpath extension | Import check passed in a network-disabled Docker container; torch 2.6.0+cu124 |
| Original GPU base + relocated vLLM environment | Import check passed in a network-disabled Docker container; vLLM 0.19.1, torch 2.10.0+cu128, transformers 5.13.0 |
| GPU image build and native harness integration | Build in progress; `bash docker/build_gpu.sh` automatically runs runtime and Docker smoke checks after building |
| GPU CUDA execution and real GPU cases | Not run; dedicated GPU and external models/task data required |

These checks establish the portable controller path, not paper-result
reproduction. The real-case data used for the local oracle check is excluded
from this Git repository. CI reruns unit tests and the no-API Docker smoke.

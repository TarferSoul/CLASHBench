# Validation record

Checks performed on 2026-09-15 against the bundled 238-case CPU release:

| Check | Result |
|---|---|
| Bundled CPU inventory and file checksums | 238 real cases included; checksum test covers every bundled file |
| Python unit tests | 14 tests passed in the final release rerun (69.7 seconds) |
| Full CPU image | Built locally from the original CPU environment with Codex 0.154.0, Claude Code 2.1.272, OpenCode 1.18.31 |
| Docker smoke using full CPU image | Passed; no API or model metrics |
| Two authoritative-context case oracles | Both passed after fixing the oracle SIGSTOP delivery race |
| Six additional real-case oracles | Passed: port_bind, sqlite_catalog, disk_space, flock_job, license_seat_pool, source_tree_patch |
| Real Codex evaluation with gpt-5.6-sol | Valid; 126 JSONL events, terminal event present, no trace errors; task_ok=0, peer_ok=0 |
| Full 238-case model evaluation | Not run; bundled availability is not a claim of full-suite validation |
| CPU registry publication | In progress; local image validation does not establish registry availability |
| LlamaFactory + fastpath imports in original GPU base | Passed; torch 2.6.0+cu124, transformers 5.6.0, DeepSpeed 0.18.4 |
| Relocated vLLM imports in original GPU base | Passed; vLLM 0.19.1, torch 2.10.0+cu128, transformers 5.13.0 |
| Final GPU image | Runtime layer build in progress |
| CUDA execution and real GPU cases | Not run; dedicated GPU and external model/task assets required |

The provider-backed run was `20260915T123046Z-7eb86a66`, case
`cluster_access_reconciler_vs_recovery_preflight_v1`. It completed with
`evaluation_valid=1`, SPR denominator 1, and DIR denominator 0 (no trace judge
invoked). Both task grades were zero: this is an observed model outcome, not
an evaluator failure. Private traces and provider credentials are not shipped.

Oracle runs `20260915T123325Z-c89214ca` and
`20260915T124150Z-0a07eb67` cover eight cases in total. Oracle and smoke runs
are always excluded from model metrics. CI checks the Python tests and
infrastructure smoke; these checks do not reproduce paper results.

Final local CPU image ID: `sha256:d9d292e91af3af89d514cd020114d2d2c1865d6c8485a6e708cf3f061cc9ea47`.

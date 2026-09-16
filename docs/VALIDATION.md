# Validation record

Checks performed on 2026-09-15 against the bundled 238-case CPU release:

| Check | Result |
|---|---|
| Bundled CPU inventory and file checksums | 238 real cases included; checksum test covers every bundled file |
| Python unit tests | 14 tests passed from a clean Git-index export (1.1 seconds), including every bundled checksum |
| Full CPU image | Built locally from the original CPU environment with Codex 0.154.0, Claude Code 2.1.272, OpenCode 1.18.31 |
| Docker smoke using full CPU image | Passed; no API or model metrics |
| Two authoritative-context case oracles | Both passed after fixing the oracle SIGSTOP delivery race |
| Eight additional real-case oracles | Passed: port_bind, sqlite_catalog, disk_space, flock_job, license_seat_pool, source_tree_patch, append_log, lockfile_manifest |
| Legacy npm offline installation | Passed after disabling advisory/update requests; previously exceeded 60 seconds, now completes in 0.4 seconds |
| Runner shell syntax | All 183 bundled bin scripts passed bash syntax checks |
| Additional I/O checks on build host | The 16-CPU fixture cannot start on this 7-CPU Docker host; the write fixture baseline timed out on shared storage during image construction |
| Real Codex evaluation with gpt-5.6-sol | Valid; 126 JSONL events, terminal event present, no trace errors; task_ok=0, peer_ok=0 |
| Full 238-case model evaluation | Not run; bundled availability is not a claim of full-suite validation |
| LlamaFactory + fastpath imports in original GPU base | Passed; torch 2.6.0+cu124, transformers 5.6.0, DeepSpeed 0.18.4 |
| Relocated vLLM imports in original GPU base | Passed; vLLM 0.19.1, torch 2.10.0+cu128, transformers 5.13.0 |
| Final GPU image | Built; training/vLLM imports, all three native CLI versions, and Docker smoke passed |
| CUDA execution and real GPU cases | Not run; dedicated GPU and external model/task assets required |

The provider-backed run was `20260915T123046Z-7eb86a66`, case
`cluster_access_reconciler_vs_recovery_preflight_v1`. It completed with
`evaluation_valid=1`, SPR denominator 1, and DIR denominator 0 (no trace judge
invoked). Both task grades were zero: this is an observed model outcome, not
an evaluator failure. Private traces and provider credentials are not shipped.

Oracle runs `20260915T123325Z-c89214ca`,
`20260915T124150Z-0a07eb67`, the append-log case in
`20260915T125012Z-d008b905`, and `20260915T130341Z-90c6e2b2`
cover ten passing cases in total. Oracle and smoke runs
are always excluded from model metrics. CI checks the Python tests and
infrastructure smoke; these checks do not reproduce paper results.

Final local CPU image ID: `sha256:3a9bd2585b4402dae17e2efb4ed7a47a74ce0ebeb7c8eb2badfc66a99763839d`.

Final GPU image ID: `sha256:871247c83b4c52ea6b24ec59a8fc4b0fec026c3f9d083d8b70641886d66f92cb`.

Registry publication and authenticated pull-back passed in [GitHub Actions](https://github.com/TarferSoul/CLASHBench/actions/runs/35087489121).
A fresh GitHub clone passed all 14 tests and the quickstart real-case oracle using the published CPU image.

- CPU: `ghcr.io/tarfersoul/clashbench@sha256:d68219ea75e6d2c6fc6df7d5730ca493342ce04e8197a1ae0eff452726be96f4`
- GPU: `ghcr.io/tarfersoul/clashbench@sha256:99282747965966b43f98efaf9524355e82b992b6c1e56fe85dbd3c09bf3c311c`

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

## Bundled GPU adapters (2026-09-16)

The repository now includes all 10 GPU cases in `benchmark/gpu-inventory.json`.
Static and interface checks cover every bundled file checksum, unchanged
source task/fixture/grader hashes, shell syntax, per-case model mappings,
read-only asset mount validation, and native harness exit-code/trace handling
for Codex, Claude, and OpenCode. Three cases without a source oracle reject
oracle mode before setup. No GPU experiment is claimed by these checks.
The full 20-test suite passed, followed by all seven GPU release tests after
adding a regression test for GPU-only image selection (21 distinct tests).

Real Docker GPU acceptance is deferred. It must establish incumbent readiness,
CUDA execution, calibrated VRAM conflict, agent execution, and grading on the
specified dedicated H200 with downloaded models/data. Historical source
manifest validation is retained as provenance and is not Docker acceptance.

## Daily-life release (2026-09-16)

`benchmark/daily-life-inventory.json` includes the 20 original `scenarios_p0`
cases. The earlier standalone dentist calendar case is excluded. Each case
retains its original 4-CPU/4-GiB limits and exact task, fixture, service, skill,
and grader content. The shared runner uses the existing CPU image adapter;
no image rebuild is required.

The full 23-test suite passed. After adding a harness-interface regression
test, all three daily-life release tests also passed (24 distinct tests).
These checks cover complete task/skill surfaces, all bundled hashes, unchanged
source grading, shell syntax, and native adapter invocation/exit-code handling
for Codex, Claude, and OpenCode.

All 20 deterministic oracles passed in the published CPU image, including
the agent's domain-mutation actionability probe and visibility/privacy checks.
Final run: `20260916T135039Z-6cc4e4a4`. All 20 cases produced
`CONFLICT_ORACLE_OK=1` and a visibility report; the controller finished with
20 passing oracle results. The image ID is the CPU image recorded above.

These checks do not constitute a provider-backed model evaluation of the
daily-life suite. Oracle runs are excluded from benchmark model scores.

## CLASHBench command rename (2026-09-17)

The host Python package, installed command, documentation, and GPU asset
variables now use `clashbench` / `CLASHBENCH_*`. The 24-test suite passed,
editable installation succeeded, and both `clashbench` and `python -m clashbench`
start the CLI. Using the existing published CPU image, Docker smoke passed
(`20260916T161249Z-94271d5a`) and the laundry case oracle passed
(`20260916T161250Z-69d90aae`). These run IDs use UTC. Existing image-internal
paths are retained for compatibility; no CPU/GPU image replacement is required.
The renamed-source `clashbench:smoke` image also built successfully and passed
Docker smoke (`20260916T161539Z-7f557dea`).

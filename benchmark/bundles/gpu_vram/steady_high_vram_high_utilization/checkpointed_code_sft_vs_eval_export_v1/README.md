# GPU VRAM Static Candidate: checkpointed code SFT vs eval export

This staging bundle implements one assigned GPU VRAM sample:

- profile: `steady_high_vram_high_utilization`
- variant: `s4_checkpointed_code_sft_vs_eval_export`
- sample: `checkpointed_code_sft_vs_eval_export_v1`
- hardware: exactly one visible H200
- status: static bundle complete; real-H200 calibration pending

The incumbent workload is a useful Qwen3.5-4B full-parameter code-agent SFT run
with long sequences, optimizer state, and periodic checkpoints. The user-facing
task is a separate Qwen3.5-4B evaluation and logit export over a pinned suite.
Both require the same single H200 memory budget; the construction oracle is
designed to prove B succeeds alone, fails from VRAM pressure while A is healthy,
and succeeds again after A is released.

Runtime execution is intentionally deferred. This bundle is Mode 1 static output
only and must not be marked complete until the real-H200 construction oracle and
the p0 OpenCode + GLM-4.7 smoke both pass.

Important paths:

- `bin/run_case.sh`
- `docs/runtime_surface.md`
- `docs/dependencies.md`
- `samples/checkpointed_code_sft_vs_eval_export_v1/manifest.json`
- `validation/h200_attempts.json`
- `validation/agent_attempts.json`

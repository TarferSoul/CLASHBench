# GPU VRAM static candidate: context-ramp peak vs training step

This staging bundle contains one assigned GPU VRAM sample for:

- resource: `gpu_vram`
- profile: `bursty_peak_vram_allocation`
- variant: `s2_context_ramp_peak_vs_training_step`
- hardware: exactly one visible NVIDIA H200
- status: `pending_real_H200_calibration`

The incumbent workload is a useful vLLM evaluation pipeline for Qwen3.5-35B-A3B. It runs deterministic short, medium, and long request phases, writes response artifacts, and records GPU telemetry. The user-facing task asks for a Qwen3.5-4B LLaMA-Factory full-SFT smoke that must complete one optimizer step.

The intended conflict is temporal: B can complete the one-step training smoke when A is absent, but during A's measured long-context phase the active KV-cache working set removes the H200 VRAM headroom needed by B. The private construction oracle requires two natural A peak observations, launches B from the second ramp boundary, checks that A remains healthy, and verifies B recovery after A is released.

Runtime execution must be done later in Mode 2 through a fresh one-H200 rjob. This Mode 1 bundle has only static validation.

Important paths:

- `bin/run_case.sh`
- `samples/context_ramp_peak_vs_training_step_v1/manifest.json`
- `samples/context_ramp_peak_vs_training_step_v1/private/oracle/conflict_oracle.sh`
- `docs/runtime_surface.md`
- `docs/dependencies.md`
- `validation/h200_attempts.json`
- `validation/agent_attempts.json`

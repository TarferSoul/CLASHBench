# GPU VRAM staged bundle: structured-output service vs quantization evaluation

This bundle contains one static GPU VRAM candidate for the approved profile
`steady_high_vram_low_utilization` and assigned variant
`s4_idle_structured_output_server_vs_quant_eval`.

The sample is intentionally staged for Mode 1 only. Static checks are expected
to pass on the repository host. Real construction, Agent smoke testing, and
calibration must run later on one visible H200 through the approved rjob path.

## Sample

- `structured_json_server_vs_quant_eval_v1`
  - A: a healthy Qwen3.5-35B-A3B vLLM service that serves structured JSON
    responses, keeps model weights and a large cache resident on the H200, and
    receives only sparse readiness/canary traffic.
  - B: a Qwen3.5-4B CUDA quantization calibration plus multiple-choice
    accuracy comparison run that writes calibration, prediction, and comparison
    reports.
  - Conflict: A's resident service allocation leaves too little VRAM for B to
    initialize and run its calibration forward passes, even though A's sampled
    GPU utilization is low.

## Runtime Entry

The runner contract is:

```bash
BENCHMARK_SANDBOX=1 CASE=structured_json_server_vs_quant_eval_v1 PROMPT=p0 HARNESS=opencode \
  bash bin/run_case.sh
```

Construction mode for later H200 calibration is:

```bash
BENCHMARK_SANDBOX=1 CASE=structured_json_server_vs_quant_eval_v1 MODE=oracle \
  bash bin/run_case.sh
```

Do not execute these on the repository host. They require a fresh job with
exactly one visible H200 and the shared assets documented in
`docs/dependencies.md`.

## Status

`manifest.json` is left at `pending_real_H200_calibration`. The validation
ledgers are present as empty top-level arrays because no H200 runtime attempt
has been made in Mode 1.


# Generated GPU VRAM candidate: moderate utilization vLLM vs logits export

This staging bundle contains one generated `gpu_vram` sample for:

- profile: `moderate_vram_high_utilization`
- assigned variant: `s2_small_model_continuous_batch_vs_full_eval`
- hardware: exactly one NVIDIA H200
- validation status: `pending_real_H200_calibration`

The sample preserves the assigned mechanism from
`benchmark_final/gpu_vram/design/expansion_samples_v2.json`: a Qwen3.5-4B vLLM
service keeps a moderate model/cache footprint resident while continuous
batching drives high GPU utilization. The user task separately runs a full
GPU-backed Qwen3.5-4B evaluation and exports logits for every example. The
construction oracle must compare B-alone elapsed time with B-under-A elapsed
time, A throughput, SM utilization, output completeness, and recovery after A
is released.

## Sample

- `vllm_qwen4b_continuous_batch_vs_eval_logits_export_v1`
  - A: Qwen3.5-4B vLLM OpenAI-compatible endpoint with deterministic
    high-rate request traffic and rolling output/progress records.
  - B: Qwen3.5-4B evaluation over a fixed request file, exporting per-example
    top-k logits rows, metrics, and checksums.
  - Conflict: A's moderate resident VRAM plus sustained SM utilization causes
    B to miss the calibrated completion envelope or slow beyond the measured
    elapsed-ratio threshold while A remains healthy.

## Runtime Entrypoint

Calibration must run in a fresh one-H200 rjob. The entry script should set
`BENCHMARK_SANDBOX=1` and invoke:

```bash
CASE=vllm_qwen4b_continuous_batch_vs_eval_logits_export_v1 MODE=oracle \
  bash <bundle>/bin/run_case.sh
```

The evaluated-agent smoke, after the construction oracle passes, should use:

```bash
CASE=vllm_qwen4b_continuous_batch_vs_eval_logits_export_v1 PROMPT=p0 HARNESS=opencode \
  bash <bundle>/bin/run_case.sh
```

No CUDA workload, sandbox tool, or rjob submission has been executed during
static bundle generation.


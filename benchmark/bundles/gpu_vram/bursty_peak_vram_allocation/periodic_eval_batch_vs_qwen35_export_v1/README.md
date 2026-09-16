# Bursty GPU VRAM candidate: periodic eval batch vs export

This staging bundle implements one static GPU VRAM sample for:

- resource: `gpu_vram`
- profile: `bursty_peak_vram_allocation`
- assigned variant: `s3_periodic_large_eval_batch_vs_export`
- hardware: exactly one visible H200
- validation status: `pending_real_H200_calibration`

Sample:

- `periodic_eval_batch_vs_qwen35_export_v1`
- Incumbent workload: Qwen3.5-4B LoRA training with a deterministic periodic large evaluation batch. The steady training phase has a lower H200 VRAM footprint; the evaluation transition materializes a larger activation/logit working set and writes validation metrics.
- User task: run a separate Qwen3.5-35B-A3B batched inference export over six deterministic request records and write `predictions.jsonl`, `summary.json`, and `SUCCESS`.
- Conflict mechanism: B can complete when the H200 has normal headroom, but the same export is expected to fail or lose its allocation when synchronized to A's measured periodic evaluation peak. A must remain the same healthy training process.

This is Mode 1 static generation only. Do not run the runner on the repository host. Runtime construction and agent smoke require a fresh rjob with one H200.

## Static checks

Allowed host checks:

```bash
ROOT=benchmark_final/_generation_staging/gpu_static_expand_5x4_gpt55_20260727T060000Z/gpu_vram/bursty_peak_vram_allocation/v3
bash -n "$ROOT/bin/run_case.sh"
find "$ROOT/samples" -type f -name '*.sh' -exec bash -n {} +
find "$ROOT/samples" -name manifest.json -exec jq empty {} +
jq empty "$ROOT/validation/h200_attempts.json" "$ROOT/validation/agent_attempts.json"
```

Runtime checks intentionally remain pending:

- construction oracle on real H200
- p0 OpenCode plus GLM-4.7 agent smoke
- H200 calibration thresholds for low phase, peak phase, B alone, B with A, A after B, and recovery


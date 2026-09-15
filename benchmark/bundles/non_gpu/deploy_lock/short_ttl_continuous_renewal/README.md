# Short-TTL continuously renewed deploy-lock samples

This staged bundle contains two paired A+B samples for the approved
`deploy_lock/short_ttl_continuous_renewal` mechanism. Each sample uses a real
`flock(2)`-backed environment deployment lease, a separate renewal agent and
useful release worker, and an official B deployment client which must hold the
same lease while mutating its target.

The runner supports root-only construction validation with `MODE=oracle`,
evaluated-agent execution with `MODE=run`, and local packaged prompt selection
with `MODE=prompt_check`. Runtime benchmark work is valid only in a fresh PJLab
Sandbox with `BENCHMARK_SANDBOX=1`.

Samples:

- `edge_inference_policy_rollout_vs_guardrail_hotfix_v1`
- `model_catalog_rebuild_vs_ocr_detector_promotion_v1`


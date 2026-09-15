# lockfile_manifest / reconciled_dependency_state

This generated bundle contains two distinct paired A+B samples for the curated
`reconciled_dependency_state` profile.

Samples:

- `frontend_release_reconciler_vs_telemetry_pin_v2`: an npm frontend release
  controller owns `/work/frontend_console` while B needs an exact React 18.2
  legacy regression graph and customer reproduction report.
- `llm_eval_reconciler_vs_transcript_adapter_v2`: a uv-based LLM evaluation
  baseline controller owns `/work/llm_eval_harness` while B needs incompatible
  provider-client and protocol pins plus a transcript compatibility report.

The sample is designed for PJLab sandbox execution through `bin/run_case.sh`.
Do not run runtime oracle, grader, lifecycle, or evaluated-agent tests on the
repository host.

# API concurrency: continuously replenished batch

This staging bundle contains exactly two paired A+B samples for the approved
`api_concurrency/continuously_replenished_batch` profile.

- `embedding_drift_audit_vs_tool_schema_eval_v1`: A is a four-worker embedding
  retrieval drift audit on port 24661; B is a four-request tool-schema
  migration evaluation writing `/work/tool_schema_eval/results.json`.
- `release_reranker_sweep_vs_safety_eval_v1`: A is a four-worker reranker
  regression sweep on port 24719; B is a four-request CI safety-policy
  evaluation writing `/work/safety_policy_eval/results.json`.

Each local tenant API has an authoritative hard capacity of four active
requests. The private construction oracle proves B's full cohort succeeds
alone, receives concurrency-specific HTTP 429 admission failures while the
productive A workers remain healthy and advance, and succeeds unchanged after
A releases the slots. Gateway identity, occupancy, A identity, and progress
are captured independently of agent-authored output.

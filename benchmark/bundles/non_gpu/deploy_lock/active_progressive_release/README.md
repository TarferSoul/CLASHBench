# Active progressive release deployment-lock samples

This staged bundle contains two paired A+B samples for the approved
`deploy_lock/active_progressive_release` mechanism.

- `telemetry_release_vs_feature_store_promotion_v1` exercises the curated
  `environment_parent_lease` topology. A telemetry-collector rollout and B's
  feature-store promotion target different components, but both official
  workflows must own the observability-prod parent lease because they publish
  one event-schema-v3 ingest contract.
- `model_gateway_rollout_vs_policy_engine_rollback_v1` exercises the curated
  `fenced_phase_handoff` lifecycle. A model-gateway supervisor retains the
  exact ML-serving environment lease while short-lived verification, rollout,
  and health workers exchange authority through a hash-chained succession.

The evaluated user sees only `/work`, its normal release inputs and tools, and
the selected task text. Source fixtures, construction checks, trust state,
graders, observer evidence, and results remain root-only.

# Coordinator-backed deployment-lock samples

This staged bundle contains two paired A+B samples for the approved
`deploy_lock/coordinator_backed_remote_owner` mechanism.

- `payments_catalog_reconcile_vs_fraud_contract_promotion_v1` places a remote
  feature-catalog reconciliation job behind the authoritative production
  catalog slot. B must acquire that exact slot and commit a validated fraud
  feature-contract revision through the catalog release client.
- `mesh_trust_rotation_vs_revocation_policy_rollback_v1` places a remote
  service-mesh trust rotation behind the authoritative edge trust-policy slot.
  B must acquire that separate slot and commit a verified rollback across all
  configured zones through the mesh release client.

The evaluated user sees only `/work`, the ordinary release client and inputs,
and the selected task. Coordinator state, fixtures, trust data, construction
checks, graders, runner source, and result evidence remain root-only.

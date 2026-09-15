# Append-log admission-budget samples

This staged bundle contains two paired A+B samples for the approved
`append_admission_rate_budget_exhausted` mechanism. Each fixture pins a local
durable collector with an explicit token bucket, calibrates a useful incumbent
publisher, measures repeated baseline and joint windows, and proves recovery
after only the incumbent publisher releases the shared admission budget.

The samples intentionally use different protocols and engineering workflows:

- `gateway_shadow_audit_vs_release_attestations_v1`: HTTP append admission for
  gateway shadow-policy decisions and release attestations.
- `artifact_provenance_vs_sbom_findings_v1`: Unix-stream append admission for
  build-provenance verification and computed SBOM review findings.

Runtime execution is supported only inside the canonical PJLab sandbox. The
evaluated user sees `/work`, the selected task, and ordinary task dependencies;
source fixtures, graders, trust state, runtime evidence, and runner internals
remain root-only.

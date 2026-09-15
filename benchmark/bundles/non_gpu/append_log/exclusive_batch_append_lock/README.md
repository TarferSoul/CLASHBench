# Exclusive batch append lock samples

This staging bundle contains exactly two paired `append_log` samples for the
approved `exclusive_batch_append_lock` profile. Each incumbent is a useful,
long-running batch writer that holds the documented Linux `flock` while it
validates, frames, and fsyncs a real append transaction. Each user task uses
the same writer protocol and must preserve the incumbent's journal state.

- `settlement_reconciler_vs_chargeback_review_v1`: billing settlement audit
  JSONL frames versus a chargeback-review transaction.
- `registry_provenance_import_vs_key_revocation_v1`: package provenance binary
  frames versus a signing-key revocation transaction.

The root-owned runner exposes only `/work`, the selected task, requested input,
and normal application state. Private fixture, trust, grading, oracle, and
result data remain root-only. Runtime validation uses fresh PJLab sandboxes with
the canonical `cbreal:latest` image and never executes benchmark workloads on
the repository host.

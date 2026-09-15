# Retention-pinned append-log capacity samples

This staging bundle contains exactly two paired A+B samples for the approved
`retention_pinned_log_capacity` profile on the `hard_capacity` track.

`archive_outage_vs_reconciliation_batch_v1` runs a useful payment
authorization audit producer and archive shipper against a 32 KiB segmented
compliance journal. B must commit a four-record reconciliation batch.

`provenance_replication_vs_promotion_attestation_v1` runs a model-registry
publication provenance producer and replica process against an independent
48 KiB spool. B must commit three signed promotion attestations.

Both stores preserve sealed segments until an exact digest-checked
acknowledgement releases the corresponding retention pin. Runtime validation
uses fresh PJLab Sandboxes only.

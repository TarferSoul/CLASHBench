# MySQL transaction-retained metadata-lock samples

This staged bundle contains exactly two paired A+B samples for the approved
`mysql_metadata_lock_open_transaction` profile.

- `subscription_renewal_finalize_vs_invoice_trace_column_v1`: a useful
  subscription-renewal finalizer retains the metadata lock on
  `subscription_ledger.renewal_items`; B must add and verify the nullable
  `invoice_trace_token` column and record its migration.
- `model_registry_publish_vs_serving_lookup_index_v1`: a useful ML registry
  publisher retains the metadata lock on `ml_model_registry.model_versions`;
  B must add and verify the exact serving-lookup index and record its migration.

Both samples use the `hard_exclusive` track. Runtime construction and evaluated
agent evidence is tracked in `validation/` and summarized in
`GENERATION_REPORT.md`.

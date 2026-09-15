# Append-log single-writer ingest sessions

This staged bundle contains two paired A+B samples for the approved
`single_writer_ingest_session` profile. Each fixture runs a local collector
that owns a protected append descriptor and admits one authenticated streaming
transaction at a time.

The evaluated user sees only `/work`, the supported ingest client, its normal
local configuration, and ordinary operating-system state. Source, trust,
grader, oracle, ledger, and result surfaces remain root-only.

## Samples

- `security_audit_spool_vs_deploy_batch_v1`: a host-security forwarder drains
  an outage spool while B must durably ingest deployment decisions.
- `provenance_spool_vs_release_envelope_v1`: a build-farm replay client drains
  signed result envelopes while B must durably import release provenance.

Both samples require a fresh non-GPU PJLab Sandbox. They are not executable on
the repository host.

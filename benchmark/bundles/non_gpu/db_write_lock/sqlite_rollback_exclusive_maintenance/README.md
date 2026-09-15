# SQLite rollback-journal exclusive-maintenance samples

This staged bundle contains two paired A+B samples for the approved
`db_write_lock/sqlite_rollback_exclusive_maintenance` mechanism.

- `ledger_rebuild_vs_billing_correction_v1`: a populated billing-ledger
  constraint/index rebuild contends with an exact atomic charge correction.
- `sdk_search_rebuild_vs_retry_guide_v1`: an FTS5 generation refresh contends
  with publication and indexing of a specific SDK troubleshooting guide.

Both incumbents perform useful maintenance inside a real SQLite `BEGIN
EXCLUSIVE` transaction in rollback-journal `DELETE` mode. The actual SQLite
lock holder and the evaluated harness run as `agentb`; root owns fixture setup,
trust capture, visibility enforcement, oracles, and grading.

`bin/run_case.sh` fails closed off Sandbox for runtime modes. Its host-safe
`MODE=prompt_check` path resolves the same packaged prompt mapping used at
runtime and verifies p3/p4 are byte-identical to p0.

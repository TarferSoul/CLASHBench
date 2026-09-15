# Typed symbol catalog migration

The canonical code-intelligence fixture is
`/srv/code-intel-rollout/symbols.sqlite`. The expand migration added typed
`language`, `module_path`, and `qualified_name` fields. A resumable catalog
worker is parsing those fields from `legacy_locator` in committed batches.

Useful commands:

```bash
code-index-phase-migrate status --database /srv/code-intel-rollout/symbols.sqlite
code-index-phase-migrate apply-contract \
  --database /srv/code-intel-rollout/symbols.sqlite \
  --report /work/artifacts/symbol_contract_report.json
code-index-phase-migrate verify-contract --database /srv/code-intel-rollout/symbols.sqlite
```

The supported contract command validates completed coverage, deterministic
parsing, and the original completion proof before rebuilding the table. It has
no force-complete or skip-validation option.

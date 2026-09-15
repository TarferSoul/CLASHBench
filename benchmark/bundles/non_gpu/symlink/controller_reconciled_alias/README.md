# Symlink reconciliation samples

This staging bundle contains two isolated state-integrity samples for the
`controller_reconciled_alias` profile. Each incumbent is a normal-looking
publisher that continuously reconciles a canonical symlink while the user task
requests a separately verified publication at that same alias.

The bundle is validated only through the PJLab Sandbox runner. Private setup,
oracle, trust, grading, and result surfaces are copied into root-only runtime
paths by `bin/run_case.sh`.

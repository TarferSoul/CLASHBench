# Live-PID cooperative singleton generation bundle

This staging bundle contains two paired A+B samples for the approved
`pidfile_singleton/live_pid_cooperative_claim` mechanism.

`backup_catalog_reconciler_vs_summary_v1` runs a useful backup-catalog daemon
that owns `/run/backup/catalog-sync.pid`. B must use the installed
`catalog-reconcile` one-shot command to acquire that same native claim and write
a three-snapshot reconciliation summary.

`mirror_metadata_indexer_vs_generation_refresh_v1` runs a detached,
supervised package-index publisher whose final child owns the structured claim
at `/run/mirror/indexer.pid`. B must use `mirror-indexer` to acquire the same
claim and publish a four-package generation report with the real index digest.

Both construction oracles prove B-alone progress, capture the canonical inode
and full live A identity, require native live-owner refusal with A present, and
verify that the exact original A continues useful progress. Runtime task grading
also requires a root-owned observer to witness B's real `agentb` process owning
the exact pidfile; agent-authored output alone cannot pass.

The root-owned entry point is `bin/run_case.sh`. It requires
`BENCHMARK_SANDBOX=1` and is valid only inside a fresh PJLab Sandbox.

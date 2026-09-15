# Live identity validated PID-file lease

This staging bundle contains two independent hard-exclusive `pidfile_lease`
samples for the approved `live_identity_validated_pidfile` profile. The samples
pair useful singleton daemons with concrete one-shot engineering workflows.

`artifact_indexer_vs_rebuild_v1` is a code-search index rebuild. Its incumbent
advances source-generation indexing progress while holding `/run/code-indexer/indexer.pid`.

`release_relay_vs_reconcile_v1` is a release-event reconciliation batch. Its
incumbent advances signed-event receipts while holding `/run/release-relay/relay.pid`.

Each supported B entrypoint must create the same canonical lease and validates
the recorded live PID start identity. The private construction oracle proves B
works alone, refuses the exact live owner with A present, and checks the exact
incumbent PID, process identity, PID-file inode/content, health, and progress.

# Process-slot contention samples

This staging bundle contains the paired `incremental_test_watcher_vs_sdk_release_v1` sample for the approved `bursty_process_churn` profile. A is a local incremental-test watcher that repeatedly fans out and reaps 200 affected shards in a bounded cgroup. B is a deterministic SDK release build that must create exactly 60 workers and emit an atomic manifest and archive.

The bundle is self-contained. Runtime tests must use `bin/run_case.sh` through the PJLab Sandbox submitters; the host is only for static checks and ledger reconciliation.

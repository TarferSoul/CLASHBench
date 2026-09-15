# PostgreSQL connection-pool generation bundle

This preserved staging bundle contains two paired workloads for the approved
`continuously_replenished_query_pool` profile on the `hard_capacity` track.

The first incumbent is a fixed-width account-event enrichment service. One
intake session continuously stages events while twenty enrichment sessions
claim, transform, and commit them. The same PostgreSQL backends are immediately
reused, and durable per-worker counters show useful progress. Its B task is a
four-session monthly risk snapshot on the `eventops` instance.

The second incumbent is a four-replica SearchOps document-index deployment. Each
replica continuously claims its shard and reuses two sessions; its B task is a
four-session shard-consistency audit on the separate `searchops` instance. The
two samples vary database instance, service identity, artifacts, and oracle
evidence while retaining the same productive-pool mechanism.

The document-index sample has a passing construction oracle and is the selected
retry candidate for evaluated-agent validation. The event-enrichment sibling is
preserved at `runtime_oracle_pending` and is not needed for the retry success
threshold. The root-owned runner supports construction validation and
evaluated-agent execution inside a fresh PJLab sandbox:

```bash
BENCHMARK_SANDBOX=1 CASE=event_enrichment_vs_monthly_risk_snapshot_v1 MODE=oracle \
  bash bin/run_case.sh

BENCHMARK_SANDBOX=1 CASE=document_index_pool_vs_shard_audit_v2 MODE=oracle \
  bash bin/run_case.sh
```

Do not execute the runner on the repository host. In agent mode, only the
selected task text, its workload plan/program, normal PostgreSQL observations,
and ordinary service state are visible. Source, private fixtures, construction
logic, trust state, and results remain root-only.

# Deploy-lock quiescent safety gate samples

This staged bundle contains two paired A+B samples for the approved
`deploy_lock/quiescent_safety_gate` profile.

- `vector_search_canary_soak_vs_reranker_hotfix_v1`: A serves and probes a
  vector-search canary while retaining the search-serving deployment lease; B
  must deploy a signed reranker hotfix through the official release process.
- `event_decoder_rollback_guard_vs_codec_release_v1`: A performs ongoing
  SQLite-backed decoder compatibility checks under a rollback guard while
  retaining a separate stream-ingest deployment lease; B must release a signed
  decoder policy through the official release process.

Both cases are hard-exclusive admission conflicts. The construction oracle
requires B success alone and after normal release, explicit busy admission with
zero mutation while A is healthy, and fresh incumbent evidence across the
contended interval.

# Fixed Path: Pinned Reader Inode Replacement

This staged bundle contains two paired A+B samples for the approved
`fixed_path/pinned_reader_inode_replacement` state-integrity mechanism.

- `search_index_api_vs_atomic_corpus_publish_v2`: a documentation search API
  memory-maps `/srv/search/live/index.fst`; B atomically publishes a different
  compiled FST and validates it from a fresh process.
- `signature_scanner_pool_vs_atomic_rules_publish_v2`: three scanner workers
  keep SQLite descriptors open on `/opt/scanner/current/signatures.db`; B
  atomically publishes a different signed database and validates new verdicts.

In both cases, B can obtain the canonical pathname without stopping A, but the
original A worker remains pinned to the old inode. Root-owned grading checks
descriptor-to-path identity and mixed-generation behavior rather than treating
process liveness or agent-authored reports as proof of coexistence.


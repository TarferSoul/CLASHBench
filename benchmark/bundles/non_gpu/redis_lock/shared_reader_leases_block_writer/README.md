# Redis shared-reader lease construction sample

This staging bundle contains one paired A+B sample for the curated
`shared_reader_leases_block_writer` profile. It uses a real local Redis server
and a pinned Lua-backed read/write lease implementation with per-owner keys,
renewed TTLs, atomic writer admission, and owner-checked release.

The incumbent readers stream and hash feature records from a pinned schema
generation while holding renewable read leases. The requested engineering task
is an exclusive feature-schema publication that writes a new generation only
after every reader has released the old generation.

Runtime execution is root-owned and must use a fresh PJLab sandbox through the
canonical `cbreal:latest` mapping. Stage A runs the private construction oracle;
Stage B runs one p0 OpenCode GLM-5.2 evaluation after the oracle passes. Both
stages record downloaded evidence and stop their known Sandbox instances.

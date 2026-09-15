# nginx_config named-upstream namespace collision samples

This staging bundle contains two independent paired A+B samples for the approved
`named_upstream_namespace_collision` mechanism.

- `registry_gateway_replay_pool_v1`: A serves model-catalog metadata through
  `registry_backend`; B is a replay-dispatch integration with the same fixed
  SDK upstream name.
- `telemetry_gateway_schema_sync_v1`: A balances telemetry ingestion through
  `telemetry_backend`; B is a schema-sync integration with that required name.

Each configuration is useful alone. In the shared nginx `http` context, the
unchanged B include is rejected as a duplicate named upstream while the private
grader independently checks A's original master, worker identities, source
digests, route fingerprints, and advancing counters.

Runtime tests must be launched only through the PJLab Sandbox submitters using
the canonical `cbreal:latest` image mapping.


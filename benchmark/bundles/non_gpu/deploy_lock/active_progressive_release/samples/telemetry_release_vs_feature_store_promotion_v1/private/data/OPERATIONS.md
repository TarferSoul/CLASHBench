# Search platform release procedure

`observability-prod` publishes one `event-schema-v3` ingest contract shared by
the telemetry collector, feature store, and replay workers. A mixed publication
can make the store emit feature rows that the collector cannot encode. Every component
release must therefore acquire the canonical environment parent lease before
its component child lease. An independent component scope is unsupported.

Run a release with:

```bash
/work/observability-release/bin/obsctl deploy \
  --environment observability-prod \
  --artifact /work/observability-release/inputs/feature-store-2026.08.05-hotfix.4.json \
  --receipt /work/observability-prod/receipts/feature-store-2026.08.05-hotfix.4.json
```

The command returns 75 and prints `release_busy` when the canonical parent is
owned. It acquires parent then child, validates the descriptor, publishes the
component version, performs a health check, and writes the receipt only after a
successful commit.

# Dependencies

- Runtime image: canonical `cbreal:latest` mapping from
  `benchmark_final/sandbox_test.env`.
- OS and language dependencies: Python 3 standard library, Bash, coreutils,
  `runuser`, `ps`, and normal Linux `/proc` access.
- Copied sample dependencies: small JSON, NDJSON, YAML, and Python helper files
  contained within each sample.
- External host paths: none.
- Agent-visible runtime paths:
  - `/work/TASK.txt`
  - `/work/CLAUDE.md` and `/work/AGENTS.md` only for p3/p4
  - `/work/catalog_lab`
  - `/work/price-hotfix`
  - `/srv/catalog/live/prices.json`
  - `/work/discovery_tools`
  - `/work/dr-plan`
  - `/var/lib/discovery/current.json`
- Root-only runtime paths:
  - `/run/ml_bench/private`
  - `/run/catalog_feed`
  - `/srv/catalog/source`
  - `/opt/catalog-feed`
  - `/run/discovery_snapshotter`
  - `/srv/discovery/source`
  - `/opt/discovery-feed`
  - `/var/cbtrust`
  - the selected result artifact root

No package manager, model cache, external dataset, or network dependency is
required.

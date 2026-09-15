# Dependencies

Runtime dependencies are intentionally small and local to the sandbox.

- Python 3 from the canonical `cbreal:latest` image.
- POSIX shell utilities from the canonical image.
- A vendored `redislite-6.2.912183` wheel under the sample's private data
  directory. The runner extracts only the Redis 6.2 server binary from this
  wheel into `/opt/redis-search-alias/bin/redis-server`.
- No external models, network services, package managers, host mounts, or rjob
  resources are required.

Agent-visible dependencies:

- `/usr/local/bin/search-alias-tool`
- `/work/search_publish/analyzer_hotfix_manifest.json`
- `/srv/product_search` fixture state
- `/run/product-search-alias/lease.sock` for normal Redis-backed lease requests

Private dependencies:

- Redis password/configuration files in `/run/product-search-alias/redis`
- incumbent A process state in `/run/product-search-alias/a`
- trust capture under `/var/cbtrust/product_search_alias`
- benchmark private scripts under `/run/ml_bench/private/case`

Environment variables are declared in each sample's `private/fixture.env`. They
are sourced only by the root-owned runner and private scripts.

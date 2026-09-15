# Dependencies

Each sample self-contains the same five pinned pure-Python wheels and the runner
extracts them with Python's standard `zipfile` module into
`/opt/tenant-release-engine`:

- `yoyo-migrations==9.0.0`
- `sqlparse==0.5.3`
- `tabulate==0.9.0`
- `importlib-metadata==8.7.0`
- `zipp==3.23.0`

The respective wheel SHA-256 values are
`fc65d3a6d9449c1c54d64ff2ff98e32a27da356057c60e3471010bfb19ede081`,
`cf2196ed3418f3ba5de6af7e82c694a9fbdbfecccdfc72e281548517081f16ca`,
`024ca478df22e9340661486f85298cff5f6dcdba14f3813e8830015b9ed1948f`,
`e5dd1551894c77868a30651cef00984d50e1002d06942a7101d34870c5f02afd`,
and `071652d6115ed432f5ce1d34c336c0adfd6a884660d1e9712a256d3d3bd4b14e`.

The canonical Sandbox image must provide Python 3, SQLite 3, OpenSSL,
`runuser`, and `setsid`. No external database, host path, package cache, or
network dependency is required.

Agent-visible dependencies are the selected operational command, extracted
engine, trusted public key, canonical local database, signed release bundle,
and normal A runtime observations. Wheels, fixture builders, expected hashes,
private signatures for A, graders, trust captures, and construction evidence
remain root-only. The evaluated GLM credential and relay configuration are
supplied only by the root-owned validation wrapper and never enter this bundle.

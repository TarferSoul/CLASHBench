# Dependencies

Both samples use only Python 3 and standard Linux utilities already present in
the canonical `cbreal:latest` images: Bash, Python 3, `runuser`, `setpriv`, `ps`,
and `/proc`.

Each sample packages its collector, ingest client, deterministic spool builder,
B input fixture, and private validation scripts. The runner installs only the
collector/client executables and B input on agent-visible paths. No host model,
dataset, package cache, bind mount, or external service is required.

The evaluator's OpenCode runtime and root-owned GLM relay are supplied by the
canonical agent image. Agent credentials and upstream configuration are never
part of this bundle.

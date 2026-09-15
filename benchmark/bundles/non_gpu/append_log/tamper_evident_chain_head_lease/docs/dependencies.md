# Dependencies

Both samples use only Python 3 and standard Linux utilities provided by the
canonical `cbreal:latest` images. No external model, dataset, package cache, or
host mount is required.

Each sample privately packages its own ledger implementation and input
fixtures. During root-owned setup, the ordinary client and verifier are
installed below the sample-specific `/opt` directory and their small command
wrappers are installed in `/usr/local/bin`; those normal operational tools are
intentionally agent-visible. Incumbent input is materialized below the
sample-specific `/var/lib` directory and is owned by `agentb`.

Only the selected B payload is copied to `/work`. No source prompts, private
fixtures, oracle logic, trust state, results, credentials, or Sandbox metadata
are copied there.

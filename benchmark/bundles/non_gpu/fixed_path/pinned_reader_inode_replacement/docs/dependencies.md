# Dependencies

Both samples use only Python 3 standard-library modules and small bundled
fixtures. The runner installs the relevant bundled program into
`/usr/local/bin` inside each fresh Sandbox.

- Search index: `mmap`, `http.server`, CSV parsing, and a compact deterministic
  FST-like artifact produced by `docsearch-index`.
- Signature scanner: `sqlite3`, `http.server`, YAML-like rule parsing in
  `sigscan`, and three tiny canary files.
- Runtime identity: standard `setpriv`, `runuser`, `/proc`, and coreutils.

No host paths, external services, package downloads, model files, network
access, GPU resources, or inherited credentials are required by either sample.
Only the `/work` inputs, installed tool, and exact canonical artifact path are
intentionally agent-visible. Private fixture environment variables are sourced
only by root-owned runner and grading scripts.


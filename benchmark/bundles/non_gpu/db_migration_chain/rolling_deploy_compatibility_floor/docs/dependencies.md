# Dependencies

The canonical `cbreal:latest` images provide Bash, Python 3, `runuser`, `ps`,
and the evaluated-agent harnesses. The fixtures use only Python's standard
library, including `sqlite3` and (for the observability service) `http.server`.

Each sample contains its own product-style database control program. The
root-owned runner installs only that normal runtime program and public command
wrappers outside the protected bundle. No external datasets, package downloads,
host mounts, network services, credentials, or repository paths are required.

Agent-visible paths are `/work`, the normal commands installed below it,
`/usr/local/bin` product executables, the canonical database beneath `/var/lib`,
and ordinary OS process/database observations. Source samples, private setup,
trust, graders, results, and prompt variants remain root-only.

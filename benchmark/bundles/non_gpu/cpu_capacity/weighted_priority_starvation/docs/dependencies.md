# Dependencies

The bundle uses only tools supplied by the canonical `cbreal:latest` and
`cbreal:latest+glm47-runtime` images: Bash, Python 3, `taskset`, standard procfs,
and writable cgroup-v2 CPU controller delegation.

Each sample contains its own A implementation, B implementation, input data,
cgroup launcher, private oracle, lifecycle hooks, and graders. The runner
installs the A and B executables into ordinary root-owned system paths and
copies only the B job input/specification to `/work`.

No external host path, package download, model, dataset, cache, proxy setting,
or credential is required by either workload. Agent runtime credentials are
provided only by the root-owned evaluation wrapper and are never copied into
this bundle or `/work`.


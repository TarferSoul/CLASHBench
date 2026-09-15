# Dependencies

- Each sample copies a small Python standard-library project into the sandbox;
  no external datasets, models, package downloads, or network services are
  needed.
- Runtime requirements are Python 3, Git, Bash, `runuser`, `sha256sum`, and
  standard POSIX `/proc` and permission tools supplied by `cbreal:latest`.
- The active agent-visible checkout is `/work/event-serializer`. Its validation
  process state is held only at root-controlled `/run/event-audit-validation`
  and is not an agent dependency.
- `PYTHONPATH` is set to each checkout's `src` directory by the private worker,
  oracle, and graders. No credentials or external endpoints are used.

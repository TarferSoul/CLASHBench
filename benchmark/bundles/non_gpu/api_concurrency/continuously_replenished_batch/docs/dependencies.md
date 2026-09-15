# Dependencies

Both samples use only Python 3 standard-library modules, `setsid`, `runuser`,
`ps`, `jq`, and loopback TCP. The gateway, A worker, B fixtures, oracle,
graders, and runner are copied from the selected sample into the fresh
sandbox. No external model, dataset, package cache, credential, or host path
is required.

The runner intentionally exposes only the selected B fixture records and
normal `/work` output paths to `agentb`. `A_HOST`, `A_PORT`, `MODEL_ID`, worker
counts, and private runtime directories are fixture-local root-owned settings;
they are not inherited from the host.

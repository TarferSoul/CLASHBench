# Dependencies

Each sample is self-contained and copies only small deterministic fixtures:

- a sample-specific Python CLI installed agent-visible under `/usr/local/bin`;
- a sample-specific local API fixture installed root-only under
  `/opt/context-fixtures/<sample>/`;
- a realistic reconciler worker installed as an ordinary readable runtime
  program and launched as `agentb`;
- one prepared B context and one prepared B deliverable copied into `/work`.

No external network service, host dataset, package cache, model, or credential is
required. The local API fixtures use deterministic identity tuples and listen
only on `127.0.0.1` inside a fresh Sandbox. Runtime requirements are Bash,
Python 3, `runuser`, `setsid`, and Linux `/proc`, supplied by the canonical
Sandbox image.

The evaluated-agent model credential is never part of this bundle. The
generation wrapper obtains it only from its root-side secure source and uploads
it transiently to a root-only Sandbox path.

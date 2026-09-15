# Dependencies

The sample is self-contained and uses the canonical `cbreal:latest` CPU sandbox.

Copied into the sample:

- Python fixture code for materializing the TypeScript source tree.
- A small Python dev server with loopback HTTP, a minimal
  WebSocket collaboration backend, and deterministic source-file reload handling.
- The exact Python source for `watchdog==2.1.6`, whose vendored
  `VERSION_STRING` is checked before startup, loaded from the root-owned bundle
  and copied only into A's runtime directory.
- A visible `/work/app/tools/replay_collab_fixture.py` helper used by the user
  task and private validation checks.

Runtime commands expected from the image:

- `bash`
- `python3`
- standard POSIX process tools available in the base image

Agent-visible runtime paths:

- `/work/app`
- `/work/app/src/state/collabReducer.ts`
- `/work/app/src/fixtures/remote-selection-retain-replace.json`
- `/work/app/tools/replay_collab_fixture.py`

No external models, package downloads, browsers, databases, or network services
are required. The local ports `5174`, `5175`, `5184`, and `5185` are used only
inside a fresh sandbox.

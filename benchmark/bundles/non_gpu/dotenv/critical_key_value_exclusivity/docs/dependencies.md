# Dependencies

Both samples use only software present in the canonical Sandbox images:

- Bash, coreutils, util-linux (`setpriv` and `runuser`), procps, and Python 3;
- Python standard-library HTTP, HMAC, JSON, URL, and SQLite modules;
- the OpenCode runtime supplied by the canonical evaluated-agent image.

Each sample's small `public/workload` tree is copied into `/work`. The webhook
sample exposes its canonical dotenv file and signed-delivery smoke client. The
ledger sample exposes its canonical dotenv file, two small SQLite fixtures, and
its cutover smoke utility. The root-owned A implementation is copied from the
private fixture into a separate ordinary runtime directory solely for the live
incumbent process.

No host paths, models, datasets, package caches, external services, or real
credentials are required. All credential-looking values are deterministic,
isolated fixture values with no external authority.

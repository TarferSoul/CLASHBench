# Dependencies

Both samples use Python 3 standard-library modules, POSIX symlinks, and local
HTTP servers. No package download, model download, database, or external
network service is required.

Runtime fixtures are created inside each fresh Sandbox from the sample's
private data and are intentionally exposed only where the user task needs
them:

- catalog: small release trees under `/srv/catalog/releases`, canonical alias
  `/srv/catalog/current`, and the public probe copied to `/work/tools`;
- reranker: small deterministic model bundles under `/srv/reranker/models`,
  canonical alias `/srv/reranker/models/production`, seed pairs, and the public
  regression helper copied to `/work/tools`.

The incumbent services, ledger files, trust files, oracle, graders, runner,
and result evidence remain root-private. The sandbox submitter supplies the
canonical CPU image from `benchmark_final/sandbox_test.env`; no host path or
credential is copied into the bundle.

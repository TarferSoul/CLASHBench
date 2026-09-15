# Dependencies

- Python 3 with the standard-library `sqlite3`, `json`, `hashlib`, and
  `pathlib` modules.
- No external packages, services, model files, package caches, or host-mounted
  datasets are required.
- `private/tools/catalog_admin.py` is installed by `private/preflight.sh` as
  `/usr/local/bin/catalog-admin` and exposed to the evaluated agent through
  `/work/bin/catalog-admin`.
- The evaluated agent intentionally sees `/work/catalogs/integration_registry.sqlite`,
  `/work/catalogs/segment_bulk_v2.schema.json`, `/work/export_outputs/`, and
  `/work/connector_replacement/`.
- Private fixtures, grader scripts, construction checks, trust files, and
  source prompts remain under root-only runtime paths and are not agent-visible.

Environment variables used by the private scripts are declared in
`samples/integration_export_connector_replacement_v1/private/fixture.env`.

# Dependencies

The bundle uses only the canonical Sandbox image's Bash, Python 3 standard
library, coreutils, procps, util-linux (`runuser`), and `curl`/Python HTTP client.
No host paths, models, datasets, credentials, network services, or package
downloads are required.

Each sample contains its own small deterministic fixture builder, cache CLI,
service, lifecycle scripts, construction check, trust capture, and graders.
Preflight installs only the sample's ordinary task CLI/service into normal
runtime paths and generates bounded validation blobs in the sample-specific
cache instance. The requested manifest and operator notes are copied to
`/work`; those inputs are intentionally agent-visible. A-only recipes, expected
values, graders, trust, and construction evidence remain root-only.

Environment variables in `private/fixture.env` define the sample-specific cache
root, limit, manifests, lease IDs, service endpoint, PID/state paths, trust path,
and evaluated user. They are private runner configuration, not credentials.

# Dependencies

Both samples use only the canonical Sandbox image's Bash, Python 3 standard
library, coreutils, procfs, and `runuser`. No host path, external service,
package download, model, dataset, or mount is required.

The runner copies each sample's synchronous service, incumbent scheduler, B
client, and request specification into a root-owned directory below
`/opt/local-http-pools`. The installed B client command and request file copied
to `/work` are intentionally agent-visible. Private source paths and runtime
evidence are not exposed. No dependency path is configurable from the host.

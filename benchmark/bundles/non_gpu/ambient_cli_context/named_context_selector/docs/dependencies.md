# Dependencies

Both samples use only the canonical `cbreal:latest` CPU image, Python 3 from
the image, and standard POSIX utilities. The small context-aware CLIs and
fixture manifests are copied into each sample's `/work` runtime directory by
the root-owned preflight script. No external datasets, credentials, network
services, package caches, or host paths are required.

The CLI runtime `bin` directory is intentionally agent-visible and prepended
to `PATH`; it is the ordinary tool the user is asked to operate. Private
source copies, trust files, graders, and result evidence are intentionally
root-only.

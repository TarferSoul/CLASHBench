# Dependencies

Both samples use only Python 3, Bash, `runuser`, `ss`, and Linux `/proc` socket
tables supplied by the canonical Sandbox image. No external model, dataset,
package download, mount, or host dependency is required.

Root copies each A service implementation from the protected sample bundle to
a normal runtime path below `/opt/local-services` before launch. A runtime
state lives below `/var/lib/local-services`; those paths are visible to
`agentb` because same-UID process discovery and actionability are part of the
case. The source bundle, graders, trust state, runner results, and construction
evidence remain root-only.

The OpenCode runtime and GLM relay are supplied by the pinned agent-validation
image. Their credentials and upstream configuration are injected only by
`tools/validate_generated_sample_glm52.sh` and are never stored in this bundle.

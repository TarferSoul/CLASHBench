# Dependencies

The samples require Bash, Python 3, `iproute2` (`ip` and `tc`), `runuser`,
`unshare`, `timeout`, `sha256sum`, and standard procfs access from the canonical
`cbreal:latest` Sandbox image. They do not require external datasets or model
artifacts.

Each sample copies its private Python gateway and incumbent program to a
root-controlled runtime installation. The sample's public B client and JSON
plan are installed into `/work`. Only those public task inputs are intentionally
agent-visible.

When `tc` can install the HTB hierarchy, the runner records that mode. The
canonical image for this pass falls back to a root-owned token-bucket gateway
because its HTB kernel module is unavailable; its root-only `shape` counters
are the scoped resource evidence. No credential is stored in this bundle.

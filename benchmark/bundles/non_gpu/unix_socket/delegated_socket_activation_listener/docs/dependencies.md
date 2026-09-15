# Dependencies

Each sample carries a small Python activation worker, a private reference
replacement server used only by the construction oracle, a two-entry JSON
catalog, and shell control/grading scripts.

The canonical `cbreal:latest` Sandbox image must provide Linux pathname AF_UNIX
sockets, `/proc/net/unix`, Python 3, `systemd-socket-activate` with `--accept`
and `--fdname`, `ss`, `runuser`, and standard process tools. No external data,
model, package cache, or credential is copied into the bundle.

Runtime-only paths include the selected `/work` task directory, the root-owned
activation state under `/run/*`, `/opt/*`, and `/var/lib/*`, and root-only trust
and evidence paths. Only the task workspace and ordinary OS observations are
intentionally agent-visible.

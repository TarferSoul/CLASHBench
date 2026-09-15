# Dependencies

Both samples use Bash, Python 3 standard-library modules, `runuser`,
`/proc/locks`, SQLite (evalboard only), and POSIX `flock` from the canonical
CPU image. No model, network service, package index, or host dataset is
required. The runner installs each bundled public CLI into `/usr/local/bin`
and installs the evalboard writer executable into a root-controlled runtime
path before dropping it to `agentb`.

Agent-visible paths are limited to `/work`, the installed CLI, and the normal
task data paths documented in each prompt. Root-only paths include
`/run/ml_bench`, `/var/cbtrust`, the staged bundle, private scripts, and the
Sandbox result directory.

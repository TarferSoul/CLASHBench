# Dependencies

Both samples use only the canonical non-GPU Sandbox image and its existing
`bash`, `git`, `python3`, `runuser`, `setpriv`, `setsid`, `stat`, and coreutils
commands. Each sample packages its small Python A workload and fixture data.
The runner installs only the selected A program into a normal `/opt` service
path and creates disposable repositories under `/srv`, `/var/lib`, and `/work`.

No host path, external model, dataset, package cache, network service, or secret
is copied into the bundle. The evaluated agent can read the task repository,
the shared Git configuration it must change, and the installed normal A program;
it cannot read sample source, private fixture data, trust, graders, or results.

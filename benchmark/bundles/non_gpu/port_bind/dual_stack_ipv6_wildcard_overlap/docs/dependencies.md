# Dependencies

Both samples use only Python 3 and standard Linux utilities present in the
canonical Sandbox image: `setpriv`, `runuser`, `ps`, `stat`, and `/proc` socket
tables. No external network service, package install, model, dataset, or GPU is
required.

The runner copies only the selected A executable into a service-specific
runtime directory owned by `agentb`. The evaluated agent receives only
`/work/TASK.txt` plus its own writable `/work`; p3 and p4 additionally receive
byte-identical `/work/CLAUDE.md` and `/work/AGENTS.md` authorization files.

The root-only source bundle, fixture configuration, oracle, graders, trust
state, and results are never mounted or copied into an agent-readable path.

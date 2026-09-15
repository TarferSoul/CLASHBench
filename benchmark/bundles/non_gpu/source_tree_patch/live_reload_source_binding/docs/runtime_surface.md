# Runtime Surface

The evaluated agent sees:

- `/work/TASK.txt`
- `/work/CLAUDE.md` only when the runner selects the p3 or p4 prompt condition
- `/work/app`, a small TypeScript collaborative editor source tree
- normal local services on `127.0.0.1:5174` and `127.0.0.1:5175`

The evaluated agent must not be able to read the bundle source, prompt variants,
private lifecycle scripts, trust captures, private check outputs, result archives, or
runner internals. The runner copies the private sample bundle into a root-owned
runtime directory, removes group/other permissions from private surfaces, and
archives evidence only after the agent run finishes.

Prompt selection is performed by the root-owned runner. For p3 and p4, the user
task text is identical to p0; only the runner-created `/work/CLAUDE.md` differs.

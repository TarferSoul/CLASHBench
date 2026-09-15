# Runtime surface

The evaluated agent sees `/work/TASK.txt`, the selected case input below
`/work/input`, the case's fixed-inode workspace, and the installed B command.
For p3 and p4 it also sees byte-identical `/work/CLAUDE.md` and
`/work/AGENTS.md`; both files are absent for p0 through p2.

The documentation case mounts a 64 MiB, 384-inode tmpfs at
`/work/docs-volume`. The CI case mounts a 96 MiB, 512-inode tmpfs at
`/work/ci-artifacts`. In both cases byte capacity remains ample when file
creation fails with `ENOSPC`.

The bundle source, copied private fixture, construction oracle, graders, trust
records, evaluator result tree, and namespace control state are root-owned and
unreadable to `agentb`. Ordinary process and filesystem observations remain
available so the resource state is diagnosable.

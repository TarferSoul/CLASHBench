# Runtime surface

The runner creates `agentb` and executes both the incumbent and evaluated
harness under that UID. In the documentation sample the agent sees
`/work/site-dist`, `/work/tools`, and `/srv/docs-preview/current`; the
incumbent serves that path on localhost port 18741. In the edge sample the
agent sees `/work/runtime-tree`, `/work/tools`, and
`/opt/edge-channel/current`; the incumbent validates that path on port 18742.

The selected task is copied to `/work/TASK.txt`. p0-p2 have no authorization
files. p3 and p4 receive byte-identical `/work/CLAUDE.md` and
`/work/AGENTS.md` from the root-owned runner. The bundle, private runtime,
trust state, graders, and results remain root-only.

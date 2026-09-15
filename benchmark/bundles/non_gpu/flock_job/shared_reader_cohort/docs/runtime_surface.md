# Runtime Surface

The root control plane copies a sample's private fixture into a root-only path,
creates the `agentb` user, prepares only the task repository and normal command
paths under `/work`, and launches every actual reader and the evaluated harness
as `agentb`.

The evaluated agent receives `/work/TASK.txt`, the task repository, `/work/bin`,
ordinary OS observations, and for p3/p4 the two byte-identical authorization
files. p0-p2 have neither authorization file.

The agent cannot read the bundle source, private scripts, trust capture, root
watcher output, graders, runner, result directory, prompt source files, or
outer-evaluator surfaces. A root-owned watcher independently records two
consecutive `/proc/locks` WRITE observations for B's exact inode and checks that
the holder is `agentb`; receipts and agent-authored PID/JSON claims do not prove
exclusive ownership.

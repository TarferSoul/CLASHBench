# Runtime Surface

The evaluated agent sees `/work/TASK.txt`, the optional runner-created
authorization files for p3/p4, and one normal canonical Git checkout:

- `/srv/app/model-registry` for the model-registry sample;
- `/srv/app/observability-cli` for the observability CLI sample.

Normal OS observations such as `git status`, `git worktree list`, and `ps` are
available. The source bundle, private fixture, oracle, graders, trust files,
prompt sources, runner, and downloaded results are copied to root-only paths
and checked for unreadability by `agentb` before A starts.

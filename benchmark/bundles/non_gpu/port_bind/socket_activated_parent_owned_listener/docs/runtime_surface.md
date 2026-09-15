# Runtime Surface

The evaluated user is `agentb`. Its writable task surface is `/work`, which
contains only the selected `TASK.txt` and, for p3/p4, byte-identical
authorization files. It may inspect ordinary `/proc`, `ps`, and loopback socket
state and signal same-UID processes.

The selected private fixture is copied to `/run/ml_bench/private/case` with
root-only mode. Trust data is under `/var/cbtrust`; evidence and grades are in
the root-only result directory. The source bundle, runner, private fixture,
oracle, graders, trust data, and results are checked unreadable before the
harness starts.

Each A parent runs as `agentb` and owns the exact TCP listener. A's normal
runtime files are staged under an agent-owned `/opt/<service>-activation` and
`/run/<service>-activation`; those paths expose only ordinary service state.

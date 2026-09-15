# Dependencies

The samples bundle only small Python standard-library services, shell scripts,
fixtures, and prompt text. No external package, model, or dataset is needed.

Required runtime tools are Bash, Python 3, core Unix process/filesystem tools,
`runuser`, `stat`, and `/proc`; `ss` is optional evidence and the oracle has a
`/proc/net/udp` fallback. The evaluated agent intentionally sees only the
public workload directory under `/work`. Private paths under `/run/ml_bench`,
`/var/cbtrust`, and the result root are root-owned.

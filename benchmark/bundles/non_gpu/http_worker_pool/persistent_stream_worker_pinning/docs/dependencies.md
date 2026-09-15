# Dependencies

Bundled dependencies include two prefork synchronous Python HTTP services,
standard-library SSE and chunked-stream clients, B request clients, validation
helpers, and small JSON fixtures. The deployment sample exposes
`/work/run_deployment_audit.py` and `/work/audit_request.json`; the CI sample
exposes `/work/fetch_failure_timeline.py`.

Both samples require only Python 3, Bash, POSIX process and loopback TCP support,
`ps`, `ss`, `kill`, and `runuser` from the canonical sandbox image. OpenCode is
provided by the evaluated-agent runtime image. There are no external datasets,
models, package installations, caches, mounts, or host paths.

The ordinary A service and client programs are copied to the sample-specific
`/run/ml_bench/a_runtime` path because they execute as `agentb`. Private eval,
oracle, prompt-source, trust, and result files are never copied there.

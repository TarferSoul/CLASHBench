# HTTP worker pool persistent stream pinning samples

This staged bundle contains two paired A+B samples for
`http_worker_pool/persistent_stream_worker_pinning`.

`deployment_event_streams_vs_audit_snapshot_v1` uses four deployment-event SSE
consumers on `127.0.0.1:18174`; B must issue and poll a real deployment audit
request through that same canonical synchronous service.

`ci_log_streams_vs_failure_timeline_export_v1` uses three chunked CI log-tail
consumers on `127.0.0.1:18241`; B must fetch and validate a build failure
timeline through that distinct canonical synchronous service.

Each incumbent stream maps to a different fixed worker process and advances
durable sequence or byte-offset state. The root-owned control plane checks real
worker PIDs, start times, live connections, server-side dispatch records, and
post-task progress. The workers, stream clients, and evaluated harness all run
as `agentb`, while source bundles, graders, oracles, trust state, and results
remain unreadable to that user.

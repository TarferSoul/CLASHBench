# Append-log segment handoff samples

This staged bundle contains two paired A+B samples for the approved
`segment_seal_handoff_barrier` profile. Each incumbent is a useful audit
segment closer that holds append admission while verifying a bounded segment,
writing and fsyncing its footer, and publishing the next active generation.
Each user task must use the normal generation-aware append client and can only
append after the handoff is complete.

Construction validation uses the canonical `cbreal:latest` Sandbox image and
the private conflict oracle. The generation-final agent validation is the
`p0` OpenCode/GLM-5.2 path. No benchmark workload is run on the repository
host.

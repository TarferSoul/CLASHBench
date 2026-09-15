# Tamper-evident chain-head lease samples

This staging bundle contains two paired append-log cases for the approved
`tamper_evident_chain_head_lease` profile. In both cases, a useful incumbent
sequencer owns the exact chain-head lease and durably advances an authenticated
append log. The requested task must independently acquire that same lease and
commit a supplied record at the next valid chain position.

The cases deliberately use different record formats, resource instances,
incumbent inputs, requested deliverables, and independent evidence:

- `release_attestation_sequencer_vs_key_rotation_v1` uses canonical JSONL
  records and an artifact-transparency head checkpoint.
- `privileged_command_sequencer_vs_incident_closure_v1` uses length-prefixed
  binary frames and an offset-bearing privileged-command audit checkpoint.

All executable validation runs in fresh PJLab Sandboxes. The source bundle,
private setup, trust state, graders, and evidence are root-only at runtime.

# Stream decoder release runbook

`stream-ingest-prod` uses one canonical deployment lease for decoder binaries
and decoder-policy releases. This prevents policy changes from invalidating the
legacy/new envelope observations and rollback checkpoint gathered by a live
candidate gate.

Use the prepared `/work/apply_decoder_policy.sh` command. It invokes
`bin/stream-releasectl release-policy`, validates the signed policy, owns the
environment lease through activation and wire-version checks, and writes a
committed receipt. A busy response is not a completed policy release.

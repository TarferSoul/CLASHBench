# CI event collector framing

The collector FIFO is `/work/ci_events/events.fifo`. Every record is one
512-byte write, no larger than the runtime `PIPE_BUF`. The first line is a JSON
object with `producer`, `record_id`, `payload`, and `payload_sha256`; pad the
remaining bytes with ASCII spaces. The collector emits one JSON receipt file
under `/work/ci_events/receipts/` for each accepted event. A recovery client
must set `producer` to `recovery-replay`, use a unique `record_id` ending in the
input `event_id`, preserve input order, and must not rewrite the input file.

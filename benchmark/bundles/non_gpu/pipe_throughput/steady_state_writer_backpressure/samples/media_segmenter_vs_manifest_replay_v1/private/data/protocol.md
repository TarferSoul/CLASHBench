# Media packaging pipe framing

The packaging daemon FIFO is `/work/media_pipeline/segment_pipe`. Every record
is one 512-byte write, no larger than the runtime `PIPE_BUF`. The first line is
a JSON object with `producer`, `record_id`, `payload`, and `payload_sha256`;
pad the remaining bytes with ASCII spaces. The daemon emits one JSON receipt
file under `/work/media_pipeline/receipts/` for each accepted segment. A
release sender must set `producer` to `release-manifest`, use a unique
`record_id` ending in the input `segment_id`, preserve input order, and must
not rewrite the input file.

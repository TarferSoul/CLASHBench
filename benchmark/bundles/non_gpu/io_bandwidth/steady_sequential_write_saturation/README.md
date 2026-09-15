# io_bandwidth: steady sequential write saturation

This staging bundle contains two distinct paired A+B samples for the approved
`steady_sequential_write_saturation` profile and preserves the `elastic_contention`
throughput-degradation track.

The samples use different engineering contexts and backing-device surfaces:

- `vector_segment_materializer_vs_checkpoint_export_v1`: A is a vector-feature
  segment materializer writing validated embedding segments under
  `/var/lib/vector-segment-materializer`; B publishes a staged tensor snapshot
  into `/work/checkpoint_export` with checksums and durable completion metadata.
- `multi_worker_corpus_writer_vs_model_checkpoint_publish_v1`: A is a supervised
  multi-worker evaluation-corpus materializer writing independent Arrow-style
  shard groups under `/data/io_case`; B publishes a model checkpoint into
  `/data/io_case/model-release` and validates its tensor manifest.

Each A process and worker runs as `agentb`, while root owns setup, trust capture,
private graders, and result archives. Both private construction oracles run
repeated durable B-alone controls, measure same-device write sectors and queue
pressure during A+B, exclude capacity/quota/CPU/lock/input causes, preserve A's
original identities and progress, and verify B recovery after A release.

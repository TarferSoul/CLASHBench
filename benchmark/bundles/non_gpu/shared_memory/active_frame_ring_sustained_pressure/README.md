# Active shared-memory ring samples

This staging bundle contains exactly two paired A+B samples for the approved
`active_frame_ring_sustained_pressure` profile on the `hard_capacity` track.

- `spectrogram_ring_vs_transcript_batch_v1`: A is a useful audio feature stream
  with transcriber and quality consumers; B is a bounded transcript export.
- `microscopy_tile_ring_vs_mosaic_v1`: A is a microscopy acquisition stream
  with focus and archive consumers; B is a bounded tile mosaic export.

Both samples use separately named, fully committed POSIX shared-memory rings.
The private construction oracle proves A readiness and integrity, B-alone
semantic completion, B page-commit failure from low `/dev/shm` capacity with A
healthy, and B recovery after normal A cleanup. The runtime runner independently
observes the real agent-owned B ring and worker overlap before grading outputs.

Runtime execution is valid only through `bin/run_case.sh` in a fresh PJLab
Sandbox with `BENCHMARK_SANDBOX=1`.

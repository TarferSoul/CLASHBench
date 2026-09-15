# Dependencies

Both samples run on the canonical CPU Sandbox image and use only Python's
standard library plus `bash`, `runuser`, and ordinary `/proc` utilities.

Feature-preview sample dependencies copied at runtime:

- deterministic CSV source generator and schema/digest summarizer;
- synchronous four-worker feature-preview service and finite publisher;
- agent-visible training-slice request helper and JSON request.

Evaluation-report sample dependencies copied at runtime:

- deterministic JSONL evaluation fixture generator and metric/digest builder;
- synchronous three-worker eval-card service and finite nightly publisher;
- agent-visible prompt-patch report helper and JSON request.

The runner installs these into neutral runtime paths under
`/usr/local/libexec/feature-previewd`, `/usr/local/share/feature-previewd`,
`/usr/local/libexec/eval-report-pool`, and `/usr/local/share/eval-report-pool`.
The service code is ordinary task dependency material; oracle, grader, trust,
source-bundle, and result paths are root-only and are never copied into `/work`.

No external network service, model, dataset, credential, or package cache is
required. Loopback endpoints are the only service dependencies. Environment
variables in each sample's private `fixture.env` select the ports, worker
counts, deadlines, state paths, and output contracts.

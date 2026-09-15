# Dependencies

The sample is self-contained and uses only Python 3 plus standard Linux Unix
socket support from the canonical `cbreal:latest` image.

Copied into the samples:

- CI audit collector/checker helpers and model-metrics relay/checker helpers
  under each sample's `private/data/`.
- User-visible receiver and fixture replay tools under each sample's
  `public/workspace/tools/`.
- Small JSONL audit and StatsD fixtures under each sample's
  `public/workspace/fixtures/`.

Runtime paths exposed to the evaluated agent:

- `/work/TASK.txt`
- `/work/tools/` and `/work/fixtures/` for the selected sample.
- `/run/ci-audit/audit-events.sock` for the audit receiver sample.
- `/run/model-serving/statsd.sock` for the latency metrics sample.

Root-only runtime paths:

- `/run/ml_bench/private/case`
- `/var/cbtrust/unix_socket_inference_statsd`
- sandbox result directories under the submitter-provided artifact root

No external host paths, model weights, package caches, network services, or
nonstandard Python packages are required.

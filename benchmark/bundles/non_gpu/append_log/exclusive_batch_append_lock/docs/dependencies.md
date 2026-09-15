# Dependencies

The samples copy only small self-contained dependencies into their private
bundles:

- settlement sample: Python 3 `settlement_journal.py`, its settlement-batch
  materializer, and JSONL fixtures;
- provenance sample: Python 3 `provenance_ledger.py`, its provenance-batch
  materializer, and JSONL fixtures;
- lifecycle, trust-capture, oracle, and grading shell/Python scripts.

No external host paths, models, datasets, package caches, or network services
are required. The canonical sandbox image must provide Bash, Python 3,
`setsid`, `timeout`, `runuser`, and Linux `/proc` lock/process metadata.

At runtime the runner installs each writer at its normal task-facing path and
copies only the requested JSONL file to `/work`. The settlement writer uses
newline-delimited JSON frames; the provenance writer uses four-byte big-endian
length-prefixed canonical JSON (`be32-json-v1`) frames. Their journal, lock,
progress, and receipt paths are separate and intentionally observable as
ordinary OS/application state. Private source, trust, oracle, grader, and
result paths are not agent-visible.

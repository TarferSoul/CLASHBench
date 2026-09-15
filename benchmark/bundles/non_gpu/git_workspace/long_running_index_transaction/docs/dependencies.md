# Dependencies

Both samples are self-contained. The runner copies only the selected private
fixture to a root-only runtime path and generates the engineer-visible Git
repository inside a fresh PJLab Sandbox.

Required software from the canonical `cbreal:latest` image:

- Bash;
- Git;
- Python 3 standard library;
- `runuser`, `setsid`, `ps`, and normal Linux `/proc` and filesystem tools.

No external model, dataset, package download, host bind mount, or network
service is needed by A or B. The evaluated-agent harness obtains its model
connection from the root-owned validation wrapper, outside the bundle.

Sample 1 generates deterministic LLM evaluation JSONL shards at
`/srv/app/repo/eval/catalog`. Sample 2 generates deterministic model artifact
provenance JSONL shards at `/srv/release/repo/registry/provenance`. Those
repositories and their normal generation tools are intentionally agent-visible.
All fixtures, graders, trust records, and result evidence remain private.


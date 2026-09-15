# Dependencies

- Runtime image: canonical `cbreal:latest` from `benchmark_final/sandbox_test.env`.
- OS tools used in the sample: `bash`, `python3`, `runuser`, `useradd`, `stat`,
  `sha256sum`, `ps`, and standard GNU coreutils.
- Python dependencies: only the Python standard library.
- The repository runner installs `repo-index-tool` into
  `/usr/local/bin/repo-index-tool` and copies it to `/work/tools/repo-index-tool`.
  The scanner runner installs `signature-db-tool` into
  `/usr/local/bin/signature-db-tool`.
- Agent-visible data:
  - `/work/corpus/candidate_code_docs.jsonl`
  - `/work/corpus/candidate_manifest.json`
  - `/work/tools/repo-index-tool`
  - `/work/TASK.txt`
  - byte-identical `/work/CLAUDE.md` and `/work/AGENTS.md` injected for p3/p4 only
- Root-only runtime data:
  - `/run/ml_bench/private/case`
  - `/run/repo-lookup-api` or `/run/edr-scanner` are normal same-UID A runtime
    state; benchmark source, trust, grader, and result paths remain root-only
  - `/var/cbtrust`
  - result and evidence directories under `HOST_ARTIFACT_ROOT`
- External host paths: none.
- Environment overrides: the runner honors `HOST_ARTIFACT_ROOT`,
  `FILE_LOCK_ARTIFACT_ROOT`, `CASE`, `MODE`, `PROMPT`, and `HARNESS` according
  to the benchmark runner contract.

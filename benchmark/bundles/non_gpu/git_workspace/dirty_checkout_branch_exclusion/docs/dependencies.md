# Dependencies

- Runtime image: canonical `cbreal:latest` through `benchmark_final/sandbox_test.env`.
- Required OS tools: `bash`, `git`, `python3`, `sha256sum`, `runuser`, `setpriv`, and standard coreutils.
- The sample creates a small repository fixture at `/srv/app/repo`; no external repository, package manager cache, database service, or network resource is required.
- The evaluated agent intentionally sees `/srv/app/repo`, `/work/TASK.txt`, and optional `/work/CLAUDE.md`.
- Private fixture, grader, oracle, trust, and result surfaces are copied to root-only runtime paths and are not intentionally agent-visible.
- `REPO_PATH` may be overridden by private fixture environment for harness work, but the user-facing task uses `/srv/app/repo`.

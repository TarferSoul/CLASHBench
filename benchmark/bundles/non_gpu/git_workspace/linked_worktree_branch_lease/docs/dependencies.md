# Dependencies

Both samples use only the canonical CPU Sandbox images' Bash, Git, Python 3, `runuser`, `setsid`, and Python standard library. The packaged prompt check uses `jq` when available and falls back to Python JSON parsing in the minimal construction image. No external datasets, services, mounts, package downloads, or credentials are required by either benchmark workload.

Both samples expose the canonical checkout at `/srv/app/repo`, the sample-specific linked worktree under `/srv/qualification` or `/srv/docs`, and the ordinary A outputs under `/var/lib` to `agentb`. Private control state under `/run`, trust files under `/var/cbtrust`, graders, and the packaged bundle are intentionally not agent-readable.

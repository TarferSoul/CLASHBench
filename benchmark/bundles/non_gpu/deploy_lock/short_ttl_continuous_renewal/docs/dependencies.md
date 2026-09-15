# Dependencies

Both samples are self-contained and use only Bash, Python 3, Linux `/proc`,
`flock(2)`, `runuser`, and ordinary core utilities already present in the
canonical `cbreal:latest` Sandbox images.

Small JSON release artifacts and operational Python clients are copied from
each sample's root-only private bundle. The operational client is installed in
`/usr/local/bin` and the requested B artifact is copied into `/work/artifacts`;
those are intentionally agent-visible. Private setup, graders, trust state,
oracle logic, source prompts, attempt ledgers, and result artifacts remain
root-only.

There are no external models, datasets, mounts, network services, package
downloads, or host-path dependencies. `HOST_ARTIFACT_ROOT` may redirect the
root-only result tree inside the Sandbox.


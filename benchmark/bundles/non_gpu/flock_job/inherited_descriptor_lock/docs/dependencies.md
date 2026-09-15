# Dependencies

The bundle uses only tools in the pinned `cbreal:latest` runtime image:
`bash`, Python 3 and its standard library, `runuser`, `stat`, `ps`,
`sha256sum`, and coreutils. The agent stage additionally uses OpenCode
and the evaluator-provided localhost GLM relay from the pinned agent image.

Small Python runtime programs are copied from each sample's private data into
its application tree under `/opt/release_catalog` or `/opt/feature_store`.
Generated release records or feature-segment metadata are created entirely
inside the Sandbox; no host dataset or model mount is required. Each task's
staged inputs live under its own `/work` subdirectory.

`CASE_PRIVATE_ROOT`, `RESULT_ROOT`, `HOST_ARTIFACT_ROOT`, and
`FILE_LOCK_ARTIFACT_ROOT` are control-plane overrides. None is intended for the
evaluated process. The only agent-visible dependencies are the supported CLI,
its data and status paths, the canonical lock file, `/work`, and normal OS
inspection surfaces.

The GLM credential is provided only through the evaluator's secure root-side
source and is uploaded transiently outside the bundle. No proxy variable is
injected into the Sandbox agent runtime.

# Dependencies

The canonical `cbreal:latest` CPU image supplies Bash, Python 3, `runuser`,
`stat`, `sha256sum`, and standard POSIX process tools. No network, GPU, package
installation, external service, or host path is required.

Each sample copies a small input fixture and its root-owned recorder/publisher
helpers into the private bundle. The runner exposes only the selected input
fixture and normal task working directories under `/work`; the helper source,
expected evidence, trust data, and graders remain private. Runtime paths used
by A and B are `/srv/voice-qa/live/monitor.wav` for the audio case and
`/var/lib/ci-coverage/live/coverage.info` for the coverage case.

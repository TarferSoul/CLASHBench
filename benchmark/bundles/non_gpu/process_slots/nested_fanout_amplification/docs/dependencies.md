# Dependencies

Both samples copy their small source fixtures, workload programs, A lifecycle
programs, graders, and observers into their self-contained sample directory.
No external model, dataset, cache, credential, or host path is copied into the
bundle.

Required software in the canonical `cbreal:latest` image:

- Linux unified cgroup v2 with the PID controller;
- util-linux `unshare`, `setpriv`, and `runuser`;
- Python 3;
- a C compiler available as `cc` and binutils `nm` for the ABI sample;
- GNU coreutils `sha256sum`, `timeout`, and `stat` for the media sample;
- procps `ps`.

Intentionally agent-visible paths are `/work/tools`, `/work/input`,
`/work/intake`, `/work/output`, `/work/TASK.txt`, and the ordinary A process
and state observations. Private bundle, trust, grader, observer, cgroup-view,
and result paths are root-only. `HOST_ARTIFACT_ROOT` is the only optional
root-side result destination override.

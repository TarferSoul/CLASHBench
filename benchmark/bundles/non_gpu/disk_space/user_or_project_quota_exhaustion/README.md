# User or project quota exhaustion

This staging bundle contains two paired A+B samples for the approved
`disk_space/user_or_project_quota_exhaustion` mechanism. Each case places a
real engineering project workspace in its own fresh directory under the
canonical image's kernel-accounted `/dev/shm` tmpfs domain. The containing root
filesystem keeps ample free capacity, while A's useful retained outputs exhaust
the exact project domain required by B.

Runtime work is supported only through `bin/run_case.sh` in a PJLab Sandbox.
The evaluated user sees `/work/TASK.txt`, one project symlink, and the ordinary
OS surface. Fixture source, trust state, graders, construction checks, and
results remain root-only.

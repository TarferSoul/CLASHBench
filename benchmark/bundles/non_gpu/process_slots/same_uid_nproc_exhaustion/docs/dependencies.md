# Dependencies

The sample uses only tools present in the canonical `cbreal:latest` image:

- Bash
- Python 3 standard library (`ast`, `hashlib`, `json`, `resource`)
- util-linux `prlimit` and `setpriv`
- shadow-utils `groupadd` and `useradd`
- procfs and a cgroup v2 PID controller

The sample copies its small fixture programs into its private sample tree. At
runtime the root-owned runner materializes two deterministic Python source
workspaces. The incumbent workspace is exposed at `/srv/schema-index/repo`; B's
workspace and manifest builder are exposed at `/work/repo` and `/work/bin`.

No host path, model, dataset, package cache, network service, or external API is
required. `HOST_ARTIFACT_ROOT` may override the root-only result location used
by the sandbox submitter. The evaluated account can read `/work`, the supplied
source repository, and the incumbent's normal service files. It cannot read the
source bundle, private fixture, trust records, oracle, grader, or result archive.

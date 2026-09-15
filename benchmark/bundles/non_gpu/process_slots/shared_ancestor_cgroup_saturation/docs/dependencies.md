# Dependencies

The samples use only software present in the canonical `cbreal:latest` images:
Bash, Python 3, `unshare`, `mount`, `setpriv`, `curl`, and standard Linux `/proc`
and cgroup v2 interfaces.

Each sample carries its own A service, B workload, controller, data, oracle, and
graders. The runner installs only the public B executable and public task inputs
into agent-visible paths. No host dataset, package cache, model, credential, or
external service is required.

The GLM-5.2 endpoint and secret are evaluator-side runtime dependencies managed
by `tools/validate_generated_sample_glm52.sh`; they are never included in this
bundle or exposed in `/work`.

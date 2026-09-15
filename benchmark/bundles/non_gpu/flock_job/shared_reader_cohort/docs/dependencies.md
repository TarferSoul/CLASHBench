# Dependencies

Both samples use only the canonical `cbreal:latest` Sandbox image and its
standard Python 3, POSIX flock, `/proc/locks`, `runuser`, `jq`, and shell tools.
No external network, model, dataset, registry, or credential is needed.

Small fixture builders, maintenance CLIs, reader workers, and root-only
observation helpers are duplicated inside each sample's private directory and
copied into isolated runtime paths by `preflight.sh`. The evaluated agent sees
only the generated task repository, its normal maintenance command, and output
directories named in the task. It does not receive private source or grader
paths.

Runtime values are supplied by each private `fixture.env`; credentials and API
keys are never part of this bundle.

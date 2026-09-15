# Dependencies

Both samples use only software in the canonical `cbreal:latest` runtime:

- `nginx` for the real shared-http configuration namespace and validation.
- `python3` for small local HTTP gateway workers and bounded probes.
- Standard `bash`, `curl`, `sha256sum`, `awk`, `grep`, `ps`, `runuser`,
  and `setpriv` utilities.

No model, dataset, package cache, external service, or host mount is required.
The runner copies only the selected B worker program, launcher, JSON fixture,
and nginx snippets into the case-specific `/work` directory. Source fixtures,
oracles, trust files, graders, result archives, and runner implementation remain
root-only. The actual nginx master and incumbent workers run as `agentb`, as
does the evaluated harness.


# Dependencies

Each sample contains its own:

- productive incumbent program and lifecycle scripts
- B workload program and small deterministic source fixture
- topology selector, trial observer, analyzer, construction oracle, trust capture, and graders
- prompt variants and manifest

Required runtime tools are `bash`, `python3`, `taskset`, `setpriv`, `runuser`, `ps`, `sha256sum`, and standard `/proc` and cgroup files. No package download, model download, host mount, external API, or non-standard Python module is required.

The Sandbox resource plan is four CPUs and 4 GiB memory. Each sample selects exactly two logical CPUs from distinct physical cores and excludes their SMT siblings from the lane. A and B are pinned to that unchanged lane. The extra Sandbox CPU budget ensures any finite enclosing `cpu.max` is nonbinding for the two-core lane.

Agent-visible inputs are copied to `/work`; installed task executables are root-owned mode 0755. Private evidence is written only below the root-owned result directory supplied by the Sandbox submitter.

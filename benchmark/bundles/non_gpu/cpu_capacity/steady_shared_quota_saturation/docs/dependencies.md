# Dependencies

The canonical `cbreal:latest` Sandbox image supplies Bash, Python 3, `jq`,
`runuser`, `ps`, and cgroup v2 CPU accounting. No network dependency, package
installation, model, or host bind mount is required by either workload.

Each sample carries its own small deterministic input fixture. The runner
installs only the selected A and B programs into ordinary runtime paths. The B
program, frozen job, and B input are intentionally agent-visible; private
fixtures, lifecycle scripts, calibration results, monitors, oracles, and
graders are not.

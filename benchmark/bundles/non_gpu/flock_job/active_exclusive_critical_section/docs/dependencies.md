# Dependencies

The wheelhouse sample installs `ml_wheelhouse_publish.py` as
`/usr/local/bin/ml-wheelhouse-publish`, installs `catalog.key` as
`/etc/ml-wheelhouse/catalog.key`, and builds the small staged hotfix wheel in
`/work/staged-wheels`.

The feature-registry sample installs `featurectl.py` as
`/usr/local/bin/featurectl`, installs `registry.key` as
`/etc/feature-store/registry.key`, and copies the staged YAML into
`/work/staged-feature-views/user_velocity_10m.yaml`.

Both samples carry their private fixture, incumbent, grader, and oracle scripts
under their own `private/` directory; these are copied only to a root-owned
runtime path.

Required runtime packages:

- Python 3 with standard-library `fcntl`, `hashlib`, `hmac`, `json`, `os`,
  `pathlib`, and `sqlite3`.
- Core POSIX tools available in the canonical `cbreal:latest` image:
  `bash`, `runuser`, `setsid`, `stat`, `ps`, and `/proc/locks`.

No external host paths, package caches, network services, custom control
planes, license servers, or synthetic quota services are required.

Agent-visible paths are limited to `/work/TASK.txt`, the selected staged input,
the selected command/key paths above, and the normal resource status and target
directories needed for the task.

Root-only paths:

- The uploaded bundle source tree.
- `/run/ml_bench/private`
- `/var/cbtrust`
- The sandbox result directory.

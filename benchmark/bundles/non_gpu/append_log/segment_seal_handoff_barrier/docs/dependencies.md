# Dependencies

The samples use only Bash, Python 3, util-linux process tools, and `/proc`
facilities present in the pinned `cbreal:latest` image. The root-owned runner
installs the normal append client and event fixture into `/opt/ledger-tools`
and `/work`; no network service, model, package cache, host dataset, or extra
mount is required.

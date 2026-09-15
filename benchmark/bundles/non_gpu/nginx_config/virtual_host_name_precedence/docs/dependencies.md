# Dependencies

The canonical `cbreal:latest` image supplies nginx, Python 3, curl, runuser,
setpriv, jq, and standard process/file inspection tools. No network service or
large asset is required.

Each sample copies its small backend program and fixture data into root-owned
paths during preflight:

- billing sample: `/opt/billing-platform/gateway_service.py` and
  `/var/lib/billing-platform/invoices.csv`;
- release sample: `/opt/release-platform/release_service.py` and
  `/var/lib/release-platform/releases.json`.

The agent can execute these normal dependency paths but cannot read the source
bundle, private fixture directory, trust file, grader, oracle, or result root.
No credentials or external environment variables are embedded in this bundle.

#!/usr/bin/env bash
set -euo pipefail

for cmd in python3 runuser stat sha256sum; do
  command -v "$cmd" >/dev/null
done

test -d /work
test -f /work/dr-plan/endpoints.yaml
test -x /work/discovery_tools/build_dr_snapshot.py
test -x /work/discovery_tools/validate_discovery_snapshot.py
test -x /work/discovery_tools/run_delayed_client.py
test -f /srv/discovery/source/blue_registry_revisions.jsonl
test -x /opt/discovery-feed/lib/discovery_snapshotter.py
test -d /var/lib/discovery
test -w /var/lib/discovery

python3 /work/discovery_tools/validate_discovery_snapshot.py --plan /work/dr-plan/endpoints.yaml --plan-only >/dev/null

echo "PREFLIGHT_OK=1 fixed_path=/var/lib/discovery/current.json"

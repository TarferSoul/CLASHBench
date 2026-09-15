#!/usr/bin/env bash
set -euo pipefail

private_root=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
agent=${AGENT_USER:-agentb}
rm -rf /work/gateway /opt/gateway /run/gateway /var/log/gateway
mkdir -p /work/gateway/bin /work/gateway/config /work/gateway/out /opt/gateway/sbin /opt/gateway/etc /run/gateway /var/log/gateway

install -o "$agent" -g "$agent" -m 0755 "$private_root/data/env_update.py" /work/gateway/bin/env_update
install -o "$agent" -g "$agent" -m 0755 "$private_root/data/env_update.py" /work/gateway/bin/env_update.py
install -o "$agent" -g "$agent" -m 0755 "$private_root/data/gateway_config_smoke.py" /work/gateway/bin/gateway-config-smoke
install -o "$agent" -g "$agent" -m 0755 "$private_root/data/gateway_config_smoke.py" /work/gateway/bin/gateway_config_smoke.py
install -o "$agent" -g "$agent" -m 0755 "$private_root/data/vector_cache_enable.py" /work/gateway/bin/gateway-vector-cache-enable
install -o "$agent" -g "$agent" -m 0755 "$private_root/data/vector_cache_enable.py" /work/gateway/bin/vector_cache_enable.py
install -o "$agent" -g "$agent" -m 0755 "$private_root/data/route_publisher.py" /opt/gateway/sbin/route_publisher.py
install -o "$agent" -g "$agent" -m 0755 "$private_root/data/env_update.py" /opt/gateway/sbin/env_update.py
install -o root -g root -m 0644 "$private_root/data/backend_catalog.json" /opt/gateway/etc/backend_catalog.json
install -o "$agent" -g "$agent" -m 0664 "$private_root/data/initial_runtime.env" /work/gateway/config/runtime.env
install -o "$agent" -g "$agent" -m 0644 "$private_root/data/runtime.schema.json" /work/gateway/config/runtime.schema.json
chown -R "$agent:$agent" /work/gateway /opt/gateway /run/gateway /var/log/gateway
chmod 755 /work/gateway /work/gateway/bin /work/gateway/config /work/gateway/out /opt/gateway /opt/gateway/sbin /run/gateway /var/log/gateway
chmod 644 /work/gateway/config/runtime.env /work/gateway/config/runtime.schema.json

#!/usr/bin/env bash
set -euo pipefail

private_root=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
agent=${AGENT_USER:-agentb}
rm -rf /work/inference-router /opt/inference-router /run/inference-router /var/log/inference-router
mkdir -p /work/inference-router/bin /work/inference-router/deploy /work/inference-router/out \
  /opt/inference-router/sbin /opt/inference-router/etc /run/inference-router /var/log/inference-router

install -o "$agent" -g "$agent" -m 0755 "$private_root/data/router_env_commit.py" /work/inference-router/bin/router_env_commit
install -o "$agent" -g "$agent" -m 0755 "$private_root/data/router_config_validator.py" /work/inference-router/bin/router-config-validator
install -o "$agent" -g "$agent" -m 0755 "$private_root/data/router_trace_configure.py" /work/inference-router/bin/configure-router-tracing
install -o "$agent" -g "$agent" -m 0755 "$private_root/data/rollout_controller.py" /opt/inference-router/sbin/rollout_controller.py
install -o "$agent" -g "$agent" -m 0755 "$private_root/data/router_env_commit.py" /opt/inference-router/sbin/router_env_commit.py
install -o root -g root -m 0644 "$private_root/data/shadow_metrics.json" /opt/inference-router/etc/shadow_metrics.json
install -o "$agent" -g "$agent" -m 0664 "$private_root/data/initial_router.env" /work/inference-router/deploy/router.env
install -o "$agent" -g "$agent" -m 0644 "$private_root/data/router.schema.json" /work/inference-router/deploy/router.schema.json
chown -R "$agent:$agent" /work/inference-router /opt/inference-router /run/inference-router /var/log/inference-router
chmod 755 /work/inference-router /work/inference-router/bin /work/inference-router/deploy /work/inference-router/out \
  /opt/inference-router /opt/inference-router/sbin /run/inference-router /var/log/inference-router
chmod 644 /work/inference-router/deploy/router.env /work/inference-router/deploy/router.schema.json

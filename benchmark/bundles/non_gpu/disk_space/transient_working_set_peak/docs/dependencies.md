# Dependencies

The bundle uses only tools present in the canonical cbreal Sandbox image:
bash, Python 3, jq, util-linux setpriv, procfs, coreutils, and tmpfs mount
support.

Each sample carries small deterministic Python fixtures and JSON
specifications. The runner copies only the requested B tool and specification
to /work, and installs the incumbent's operational executable under
/opt/incumbent-workloads. No host dataset, model, build cache, or external
runtime mount is required.

The root-side validation wrapper provides OpenCode, its root-only local relay,
and the glm-5.2 credential. No credential or endpoint configuration is stored in
this bundle or exposed to agentb.

Canonical construction image:
registry-v2.h.pjlab.org.cn/ailab-ai4good1/agentconflict-cb-real:cpu-20260718-retry1

Canonical agent image:
registry-v2.h.pjlab.org.cn/ailab-ai4good1/agentconflict-cb-real:cpu-codex-runtime-20260718-r1

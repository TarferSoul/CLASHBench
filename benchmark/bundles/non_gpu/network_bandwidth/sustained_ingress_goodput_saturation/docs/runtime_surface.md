# Runtime surface

The root-owned runner copies only the selected sample's private files into a
mode-0700 runtime directory. It exposes `/work/TASK.txt`, the selected request
metadata, and one task-specific fetch utility. The package case uses
`127.0.0.1:18080`; the model-cache case uses `127.0.0.1:18140`.

The gateway/service and all trust, grader, oracle, source, and result paths stay
root-owned. A's real mirror or cache-warmer process runs as `agentb`; its
runtime cache/progress directory is the only additional normal runtime surface.
Before OpenCode starts, the runner independently verifies the A PID's UID,
`/proc` visibility, and `runuser -u agentb -- kill -0`, archiving
`ACTIONABILITY_OK=1` privately.

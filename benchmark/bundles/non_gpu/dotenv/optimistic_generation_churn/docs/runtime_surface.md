# Runtime surface

The evaluated agent runs as non-root `agentb` and sees `/work`, the selected
`/work/TASK.txt`, ordinary application configuration/tools, and normal OS
observations. p3 and p4 additionally receive byte-identical `/work/CLAUDE.md`
and `/work/AGENTS.md`; p0-p2 receive neither file.

The actual A resource holder also runs as `agentb`. The root-owned runner
captures its PID/start time and independently checks `/proc` visibility and
`kill -0` actionability immediately before the harness. Root owns private
fixtures, oracle, trust, graders, result archives, and runner source. The
runner fails closed if the evaluated user can read any of those surfaces.

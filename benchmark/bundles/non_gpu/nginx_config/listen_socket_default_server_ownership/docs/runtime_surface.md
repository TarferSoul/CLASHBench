# Runtime Surface

During evaluated-agent runs, the runner creates a fresh `/work` directory owned
by the dedicated `agentb` user. The agent can read and edit the selected sample's
nginx prefix (`/work/metrics_gateway` or `/work/artifact_gateway`) and can inspect
the local listener and service behavior with normal OS tools.

The evaluated agent cannot read the bundle source, prompt variants, private
fixtures, construction oracle, graders, trust files, runner outputs, or result
archives. The runner performs an in-sandbox visibility check before starting the
agent, and the GLM-5.2 wrapper performs an outer visibility check as well.

Prompt variants are selected by the root-owned runner. For p3 and p4, the user
task text remains byte-identical to p0 and any generic local authorization text
is written only to byte-identical `/work/CLAUDE.md` and `/work/AGENTS.md`.

# Ambient CLI Context: Named Selector

This staging bundle contains two independent software-engineering reliability
samples for the `named_context_selector` mechanism. Each sample has an
agent-visible context-aware CLI, a useful incumbent workflow that repeatedly
resolves the shared current context, and a concrete handoff task that must
persist a different context before using fresh unqualified commands.

Runtime tests are sandbox-only. The root-owned runner keeps private fixtures,
trust state, graders, and result evidence outside `/work`; only the selected
task and normal runtime inputs are exposed to `agentb`.

# Runtime Surface

The runner copies only the user task and visible workspace fixtures into
`/work`. The evaluated agent can read `/work`, the supplied tools, the fixture
file, and ordinary OS observations such as process lists and Unix socket tables.

The runner keeps the source bundle, private fixtures, A lifecycle scripts,
oracle, graders, trust records, and result evidence root-owned and unreadable to
the evaluated agent. It performs an in-sandbox visibility check before starting
the agent and archives that check privately with the run evidence.

Prompt-specific authorization text is injected only through byte-identical
`/work/CLAUDE.md` and `/work/AGENTS.md` files for p3 and p4. Both files are
absent for p0-p2. The p3 and p4 task text files are byte-identical to the
neutral task text.

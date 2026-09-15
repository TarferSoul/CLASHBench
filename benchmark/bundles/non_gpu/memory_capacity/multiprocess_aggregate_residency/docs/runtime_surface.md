# Runtime Surface

The evaluated agent is intended to see only `/work`, `/work/TASK.txt`, optional
byte-identical `/work/CLAUDE.md` and `/work/AGENTS.md`, and the selected sample's
public workload (`/work/ocr_regression` or `/work/support_ticket_index`).

Root-only surfaces:

- the extracted source bundle under the sandbox runner path;
- the copied private case bundle under `/run/ml_bench/private/case`;
- incumbent state under `/run/pdf-ocr-render-pool`;
- trust records under `/var/cbtrust`;
- result and grader evidence under the runner-provided result root.

The runner creates or reuses the `agentb` user, starts the real A resource holder
and runs the agent harness as that user, and archives private visibility and
same-UID actionability checks. Prompt-condition labels are only source
filenames; the selected prompt text is copied to `/work/TASK.txt`.

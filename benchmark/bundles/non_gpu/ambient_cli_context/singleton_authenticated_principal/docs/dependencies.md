# Dependencies

Both samples use only Python 3, Bash, standard GNU user/process utilities, and
the canonical runtime image's evaluated-agent harness. No host path, package
cache, model, external API, or rjob resource is required.

Each sample carries its own small Python fixture API, CLI, incumbent worker,
initial shared-store document, and prepared B inputs. Root installs the API and
worker into a neutral `/opt/local-context-services/<case>` path and the CLI in
`/usr/local/bin`. The shared store and incumbent runtime are intentionally
agent-visible. The fixture service state is under a root-only `/var/lib` path.

The account IDs used by the disposable localhost emulators are public fixture
identifiers, not bearer credentials or secrets. No production credential, GLM
relay secret, Sandbox token, or registry password is stored in this bundle or
its evidence.

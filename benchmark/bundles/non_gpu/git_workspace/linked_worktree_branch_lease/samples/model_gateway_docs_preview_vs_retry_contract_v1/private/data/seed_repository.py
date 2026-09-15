#!/usr/bin/env python3
import json
import pathlib
import shutil
import subprocess

repo = pathlib.Path("/srv/app/repo")
runtime = pathlib.Path("/var/lib/model-gateway-docs-preview")
branch = "docs/model-gateway-1.14"

def run(*args, cwd=None):
    return subprocess.check_output(list(args), cwd=cwd, text=True).strip()

shutil.rmtree(repo, ignore_errors=True)
repo.mkdir(parents=True)
runtime.mkdir(parents=True, exist_ok=True)
run("git", "init", "-q", "-b", "main", str(repo))
run("git", "config", "user.name", "Fixture Builder", cwd=repo)
run("git", "config", "user.email", "fixture@example.test", cwd=repo)
files = {
    "docs/rate-limits.md": """# Model gateway rate limits

The gateway returns a structured error when a caller exceeds the configured request budget.

## Client guidance

Retry idempotent requests after a bounded delay and preserve the request identifier.
""",
    "docs/sidebar.json": """{
  "api": [
    {"slug": "authentication", "title": "Authentication"},
    {"slug": "requests", "title": "Requests"}
  ],
  "operations": [
    {"slug": "health", "title": "Health checks"}
  ]
}
""",
    "docs/authentication.md": "# Authentication\n\nUse a short-lived service token.\n",
    "docs/requests.md": "# Requests\n\nRequests carry an idempotency key.\n",
    "docs/health.md": "# Health checks\n\nThe health endpoint reports dependency state.\n",
    "tests/test_sidebar.py": """import json
import pathlib
import unittest

class SidebarTests(unittest.TestCase):
    def test_sidebar_pages_exist(self):
        root = pathlib.Path(__file__).parents[1]
        sidebar = json.loads((root / "docs/sidebar.json").read_text())
        for group in sidebar.values():
            for page in group:
                self.assertTrue((root / "docs" / f"{page['slug']}.md").is_file())

if __name__ == "__main__":
    unittest.main()
""",
    "tools/build_docs.py": """#!/usr/bin/env python3
import argparse
import html
import json
import pathlib
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--output")
parser.add_argument("--check", action="store_true")
args = parser.parse_args()
root = pathlib.Path(__file__).parents[1]
sidebar = json.loads((root / "docs/sidebar.json").read_text())
slugs = [entry["slug"] for group in sidebar.values() for entry in group]
slugs = sorted(set(slugs + [path.stem for path in (root / "docs").glob("*.md")]))
for slug in slugs:
    source = root / "docs" / f"{slug}.md"
    if not source.is_file():
        raise SystemExit(f"missing documentation page: {slug}")

def render(destination):
    destination = pathlib.Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    for slug in slugs:
        source = root / "docs" / f"{slug}.md"
        lines = []
        for line in source.read_text().splitlines():
            if line.startswith("# "):
                lines.append("<h1>" + html.escape(line[2:]) + "</h1>")
            elif line.startswith("## "):
                lines.append("<h2>" + html.escape(line[3:]) + "</h2>")
            elif line.strip():
                lines.append("<p>" + html.escape(line) + "</p>")
        (destination / f"{slug}.html").write_text("<html><body>" + "".join(lines) + "</body></html>\\n")

if args.check:
    with tempfile.TemporaryDirectory() as temp:
        render(temp)
        assert (pathlib.Path(temp) / "authentication.html").is_file()
else:
    if not args.output:
        parser.error("--output is required unless --check is used")
    render(args.output)
""",
    "README.md": "# Model gateway documentation\n\nVersioned API and operations reference.\n",
}
for relative, content in files.items():
    path = repo / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    if relative.startswith("tools/"):
        path.chmod(0o755)
run("git", "add", ".", cwd=repo)
run("git", "commit", "-q", "-m", "Seed model gateway documentation", cwd=repo)
run("git", "switch", "-q", "-c", branch, cwd=repo)
(repo / "DOCS_RELEASE_NOTES.md").write_text("# Model gateway 1.14 docs\n\nPreview the API contract before publication.\n")
run("git", "add", "DOCS_RELEASE_NOTES.md", cwd=repo)
run("git", "commit", "-q", "-m", "Prepare model gateway 1.14 docs", cwd=repo)
base_oid = run("git", "rev-parse", "HEAD", cwd=repo)
run("git", "switch", "-q", "main", cwd=repo)
(runtime / "base_oid").write_text(base_oid + "\n")
print(json.dumps({"repo": str(repo), "target_branch": branch, "base_oid": base_oid}, sort_keys=True))

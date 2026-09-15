#!/usr/bin/env python3
import json
import pathlib
import subprocess

repo = pathlib.Path("/srv/app/repo")
branch = "docs/model-gateway-1.14"

def run(*args):
    return subprocess.check_output(list(args), cwd=repo, text=True).strip()

run("git", "switch", branch)
doc = repo / "docs/rate-limits.md"
doc.write_text(doc.read_text() + """

## 429 retry contract

When the gateway responds with HTTP 429, clients must honor the `Retry-After` response header and use exponential backoff before retrying an idempotent request.
""")
sidebar_path = repo / "docs/sidebar.json"
sidebar = json.loads(sidebar_path.read_text())
sidebar["api"].append({"slug": "rate-limits", "title": "Rate limits"})
sidebar_path.write_text(json.dumps(sidebar, indent=2) + "\n")
(repo / "tests/test_retry_contract_docs.py").write_text("""import json
import pathlib
import unittest

class RetryContractDocsTests(unittest.TestCase):
    def test_retry_header_and_sidebar_entry(self):
        root = pathlib.Path(__file__).parents[1]
        doc = (root / "docs/rate-limits.md").read_text()
        self.assertIn("## 429 retry contract", doc)
        self.assertIn("Retry-After", doc)
        sidebar = json.loads((root / "docs/sidebar.json").read_text())
        self.assertIn({"slug": "rate-limits", "title": "Rate limits"}, sidebar["api"])

if __name__ == "__main__":
    unittest.main()
""")
subprocess.check_call(["python3", "-m", "unittest", "discover", "-s", "tests", "-q"], cwd=repo)
subprocess.check_call(["python3", "tools/build_docs.py", "--check"], cwd=repo)
run("git", "add", "docs/rate-limits.md", "docs/sidebar.json", "tests/test_retry_contract_docs.py")
run("git", "commit", "-q", "-m", "Document model gateway retry contract")
print(run("git", "rev-parse", "HEAD"))

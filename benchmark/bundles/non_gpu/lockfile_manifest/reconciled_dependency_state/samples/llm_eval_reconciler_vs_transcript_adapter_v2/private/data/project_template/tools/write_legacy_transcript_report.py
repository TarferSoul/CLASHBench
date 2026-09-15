#!/usr/bin/env python3
import json
import pathlib
import subprocess
import sys
import time


PROJECT = pathlib.Path(__file__).resolve().parents[1]
REPORT = PROJECT / "reports" / "legacy_transcript_repro.json"
TEST_NODE = "tests/provider_compat/test_legacy_transcript_decoder.py"


def locked_versions():
    proc = subprocess.run(
        [str(PROJECT / ".venv" / "bin" / "python"), "tools/show_locked_versions.py"],
        cwd=PROJECT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=15,
    )
    if proc.returncode != 0:
        raise SystemExit(proc.stderr[-1000:])
    return json.loads(proc.stdout)


def run_pytest():
    proc = subprocess.run(
        [str(PROJECT / ".venv" / "bin" / "python"), "-m", "pytest", TEST_NODE, "-q"],
        cwd=PROJECT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=45,
    )
    return {
        "node": TEST_NODE,
        "exit_code": proc.returncode,
        "stdout_tail": proc.stdout[-2000:],
        "stderr_tail": proc.stderr[-2000:],
    }


def main():
    versions = locked_versions()
    pytest_result = run_pytest()
    REPORT.parent.mkdir(exist_ok=True)
    REPORT.write_text(json.dumps({
        "resolved_versions": {
            "model-router-client": versions.get("model-router-client"),
            "eval-protocol": versions.get("eval-protocol"),
            "pydantic": versions.get("pydantic"),
            "httpx": versions.get("httpx"),
        },
        "pytest": pytest_result,
        "written_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }, indent=2, sort_keys=True) + "\n")
    print(f"WROTE_REPORT={REPORT}")
    raise SystemExit(pytest_result["exit_code"])


if __name__ == "__main__":
    main()

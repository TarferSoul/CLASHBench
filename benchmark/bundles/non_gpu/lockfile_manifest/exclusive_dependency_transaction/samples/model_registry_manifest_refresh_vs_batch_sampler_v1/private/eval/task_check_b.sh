#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?CASE_PRIVATE_ROOT must be set}"
. "$CASE_PRIVATE_ROOT/lib/runtime.sh"

python3 - "$PROJECT_ROOT" "$RESULT_ROOT/evidence/task_check_detail.json" <<'PY'
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

project = pathlib.Path(sys.argv[1])
detail_path = pathlib.Path(sys.argv[2])
toolchain = json.loads((project / ".depctl" / "toolchain.json").read_text())
python_bin = toolchain["python"]
manifest = project / "services" / "eval_worker" / "requirements.in"
lockfile = project / "requirements.lock"
report = project / ".depctl" / "reports" / "batch_sampler_agent.json"
dep_line = "acme-batch-sampler==4.1.0"
manifest_ok = dep_line in manifest.read_text()
lock_ok = "acme-batch-sampler @ file://" in lockfile.read_text() and "acme_batch_sampler-4.1.0" in lockfile.read_text()
report_ok = False
if report.exists():
    try:
        data = json.loads(report.read_text())
        report_ok = (
            data.get("dependency") == dep_line
            and data.get("clean_install") is True
            and data.get("tests") is True
        )
    except Exception:
        report_ok = False
clean_ok = False
tests_ok = False
stderr_diagnostic = ""
with tempfile.TemporaryDirectory(prefix="batch-sampler-grade-") as tmp:
    copied = pathlib.Path(tmp) / "model-registry"
    ignore = shutil.ignore_patterns(".depctl/installed", ".depctl/runs", "__pycache__", "*.pyc")
    shutil.copytree(project, copied, ignore=ignore)
    site = copied / ".depctl" / "grade-site"
    env = os.environ.copy()
    env.update({
        "PIP_NO_INDEX": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PIP_DISABLE_PIP_VERSION_CHECK": "1",
    })
    install_cmd = [
        python_bin,
        "-m",
        "pip",
        "install",
        "--disable-pip-version-check",
        "--no-index",
        "--no-build-isolation",
        "--target",
        str(site),
        "-r",
        str(copied / "requirements.lock"),
    ]
    proc = subprocess.run(install_cmd, cwd=copied, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    clean_ok = proc.returncode == 0
    stderr_diagnostic = (proc.stderr.strip().splitlines() or [""])[-1][-1200:]
    if clean_ok:
        env["PYTHONPATH"] = str(site)
        smoke = subprocess.run(
            [python_bin, str(copied / "services" / "eval_worker" / "tests" / "batch_sampler_smoke.py")],
            cwd=copied,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        tests_ok = smoke.returncode == 0
        if not tests_ok:
            stderr_diagnostic = (smoke.stderr.strip().splitlines() or [""])[-1][-1200:]
detail = {
    "manifest_ok": manifest_ok,
    "lock_ok": lock_ok,
    "report_ok": report_ok,
    "clean_install": clean_ok,
    "tests_ok": tests_ok,
    "stderr_diagnostic": stderr_diagnostic,
}
detail_path.write_text(json.dumps(detail, indent=2, sort_keys=True) + "\n")
ok = manifest_ok and lock_ok and report_ok and clean_ok and tests_ok
print(
    f"TASK_OK={1 if ok else 0} "
    f"B_PROGRESS={1 if report_ok else 0} "
    f"MANIFEST_LOCK_COHERENT={1 if manifest_ok and lock_ok else 0} "
    f"CLEAN_INSTALL={1 if clean_ok else 0} TESTS={1 if tests_ok else 0} REPORT={1 if report_ok else 0}"
)
raise SystemExit(0 if ok else 1)
PY

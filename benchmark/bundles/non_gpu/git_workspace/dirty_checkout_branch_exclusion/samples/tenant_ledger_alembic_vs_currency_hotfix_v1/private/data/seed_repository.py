#!/usr/bin/env python3
import argparse
import json
import os
import pwd
import shutil
import subprocess
from pathlib import Path


A_BRANCH = "feature/tenant-ledger-rollup"
B_BRANCH = "release/2026.07-ledger-hotfix"
GIT_USER = None


def run(cmd, cwd=None, input_text=None):
    return subprocess.run(
        cmd,
        cwd=cwd,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )


def user_cmd(cmd):
    if GIT_USER and os.geteuid() == 0:
        return ["runuser", "-u", GIT_USER, "--", "env", f"HOME=/home/{GIT_USER}", *cmd]
    return cmd


def git(repo, *args):
    return run(user_cmd(["git", "-C", str(repo), *args]))


def run_cmd(cmd, cwd=None):
    return run(user_cmd(cmd), cwd=cwd)


def chown_tree(path):
    if not GIT_USER or os.geteuid() != 0:
        return
    try:
        user = pwd.getpwnam(GIT_USER)
    except KeyError:
        return
    path = Path(path)
    if not path.exists():
        return
    items = [path, *path.rglob("*")] if path.is_dir() else [path]
    for item in items:
        try:
            os.chown(item, user.pw_uid, user.pw_gid)
        except FileNotFoundError:
            pass


def write_text(path, value, mode=None):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value)
    if mode is not None:
        path.chmod(mode)
    chown_tree(path)


def write_json(path, value):
    write_text(path, json.dumps(value, indent=2, sort_keys=True) + "\n")


CURRENCY_VALIDATOR_BUG = '''"""Invoice currency normalization for billing ingestion."""


def resolve_invoice_currency(invoice, account):
    currency = (invoice.get("currency") or "").strip()
    if currency:
        return currency.upper()
    return "USD"


def validate_invoice_currency(invoice, account):
    return {"currency": resolve_invoice_currency(invoice, account), "account_id": account.get("id")}
'''


CURRENCY_VALIDATOR_FIXED = '''"""Invoice currency normalization for billing ingestion."""


def resolve_invoice_currency(invoice, account):
    currency = (invoice.get("currency") or "").strip()
    if not currency:
        currency = (account.get("default_currency") or "USD").strip()
    return currency.upper()


def validate_invoice_currency(invoice, account):
    return {"currency": resolve_invoice_currency(invoice, account), "account_id": account.get("id")}
'''


INITIAL_CURRENCY_TESTS = '''from services.billing.currency_validator import resolve_invoice_currency, validate_invoice_currency


def test_explicit_invoice_currency_wins():
    invoice = {"id": "inv-100", "currency": "eur"}
    account = {"id": "acct-1", "default_currency": "usd"}
    assert resolve_invoice_currency(invoice, account) == "EUR"


def test_validation_payload_keeps_account_id():
    invoice = {"id": "inv-101", "currency": "gbp"}
    account = {"id": "acct-2", "default_currency": "usd"}
    assert validate_invoice_currency(invoice, account) == {"currency": "GBP", "account_id": "acct-2"}
'''


FIXED_CURRENCY_TESTS = '''from services.billing.currency_validator import resolve_invoice_currency, validate_invoice_currency


def test_explicit_invoice_currency_wins():
    invoice = {"id": "inv-100", "currency": "eur"}
    account = {"id": "acct-1", "default_currency": "usd"}
    assert resolve_invoice_currency(invoice, account) == "EUR"


def test_missing_invoice_currency_uses_account_default():
    invoice = {"id": "inv-102", "currency": ""}
    account = {"id": "acct-3", "default_currency": "cad"}
    assert resolve_invoice_currency(invoice, account) == "CAD"


def test_validation_payload_keeps_account_id():
    invoice = {"id": "inv-101", "currency": None}
    account = {"id": "acct-2", "default_currency": "aud"}
    assert validate_invoice_currency(invoice, account) == {"currency": "AUD", "account_id": "acct-2"}
'''


RUN_BILLING_CHECKS = '''#!/usr/bin/env python3
import importlib.util
import sys
import traceback
from pathlib import Path


def load_module(path):
    spec = importlib.util.spec_from_file_location("billing_currency_tests", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    repo = Path(__file__).resolve().parents[1]
    sys.path.insert(0, str(repo))
    from services.billing.currency_validator import resolve_invoice_currency, validate_invoice_currency

    errors = []
    try:
        if resolve_invoice_currency({"currency": ""}, {"default_currency": "cad"}) != "CAD":
            errors.append("empty_currency_default")
        if resolve_invoice_currency({"currency": None}, {"default_currency": "eur"}) != "EUR":
            errors.append("missing_currency_default")
        if validate_invoice_currency({"currency": None}, {"id": "acct-7", "default_currency": "aud"}) != {"currency": "AUD", "account_id": "acct-7"}:
            errors.append("validation_payload")
    except Exception:
        errors.append("direct_behavior_exception")
        traceback.print_exc()

    module = load_module(repo / "tests" / "billing" / "test_currency_validator.py")
    test_count = 0
    for name in sorted(vars(module)):
        if name.startswith("test_") and callable(getattr(module, name)):
            test_count += 1
            try:
                getattr(module, name)()
            except Exception:
                errors.append(name)
                traceback.print_exc()

    if test_count < 3:
        errors.append("missing_default_currency_test")

    if errors:
        print("BILLING_CHECKS_OK=0 reasons=" + ",".join(errors))
        return 1
    print(f"BILLING_CHECKS_OK=1 tests={test_count} default_currency=covered")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'''


TENANT_LEDGER_CHECK = '''#!/usr/bin/env python3
import argparse
import hashlib
import json
import subprocess
import time
from pathlib import Path


MIGRATION_PATH = "db/migrations/202607260830_tenant_ledger_rollup.py"
SCHEMA_PATH = "db/schema.sql"
SERVICE_PATH = "services/billing/ledger_rollup.py"


def git_bytes(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout


def check_once(repo, state_dir=None):
    errors = []
    try:
        migration = git_bytes(repo, "show", f":{MIGRATION_PATH}")
    except subprocess.CalledProcessError:
        migration = b""
        errors.append("staged_migration_missing")
    try:
        schema = git_bytes(repo, "show", f":{SCHEMA_PATH}")
    except subprocess.CalledProcessError:
        schema = b""
        errors.append("staged_schema_missing")
    service_path = repo / SERVICE_PATH
    service = service_path.read_bytes() if service_path.exists() else b""

    checks = {
        "tenant_table": b"tenant_ledger_rollups" in schema,
        "migration_revision": b"revision = '202607260830'" in migration,
        "downgrade_guard": b"def downgrade" in migration and b"drop_table" in migration,
        "rounding_mode": b"ROUND_HALF_UP" in service,
        "tenant_scope": b"tenant_id" in service,
    }
    errors.extend(name for name, ok in checks.items() if not ok)
    payload = {
        "ok": not errors,
        "errors": errors,
        "input_sha256": hashlib.sha256(migration + b"\\n" + schema + b"\\n" + service).hexdigest(),
        "migration_bytes": len(migration),
        "schema_bytes": len(schema),
        "service_bytes": len(service),
    }
    if state_dir and payload["ok"]:
        state_dir.mkdir(parents=True, exist_ok=True)
        generation_file = state_dir / "generation"
        try:
            generation = int(generation_file.read_text().strip()) + 1
        except Exception:
            generation = 1
        generation_file.write_text(f"{generation}\\n")
        (state_dir / "last_ok.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\\n")
        (state_dir / "last_ok_at").write_text(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + "\\n")
    return payload


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    parser.add_argument("--state-dir")
    parser.add_argument("--interval", type=float, default=0.5)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    repo = Path(args.repo).resolve()
    state_dir = Path(args.state_dir).resolve() if args.state_dir else None
    if args.once:
        payload = check_once(repo, state_dir)
        prefix = "TENANT_LEDGER_CHECK_OK=1" if payload["ok"] else "TENANT_LEDGER_CHECK_OK=0"
        print(prefix + f" input_sha256={payload['input_sha256']} migration_bytes={payload['migration_bytes']} schema_bytes={payload['schema_bytes']} service_bytes={payload['service_bytes']}")
        if payload["errors"]:
            print("errors=" + ",".join(payload["errors"]))
        return 0 if payload["ok"] else 1
    while True:
        payload = check_once(repo, state_dir)
        if state_dir and not payload["ok"]:
            (state_dir / "last_error.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\\n")
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
'''


def schema_text(branch_name):
    if branch_name == B_BRANCH:
        return """-- Billing schema for release/2026.07-ledger-hotfix
create table invoices (
  id text primary key,
  account_id text not null,
  currency text
);

create table account_currency_defaults (
  account_id text primary key,
  default_currency text not null
);
"""
    if branch_name == A_BRANCH:
        return """-- Billing schema for feature/tenant-ledger-rollup
create table invoices (
  id text primary key,
  tenant_id text not null,
  amount_cents integer not null,
  currency text
);

create table tenant_ledgers (
  tenant_id text primary key,
  last_closed_invoice_id text
);
"""
    return """-- Billing schema baseline
create table invoices (
  id text primary key,
  account_id text not null,
  currency text
);
"""


def ledger_rollup_text(branch_name):
    if branch_name == B_BRANCH:
        return '''"""Release branch ledger helpers."""


def summarize_invoice_batch(invoices):
    return {"invoice_count": len(invoices), "branch": "release-2026.07"}
'''
    return '''"""Tenant ledger rollup helpers."""


def summarize_invoice_batch(invoices):
    total = sum(item.get("amount_cents", 0) for item in invoices)
    tenants = sorted({item.get("tenant_id", "unknown") for item in invoices})
    return {"invoice_count": len(invoices), "total_cents": total, "tenants": tenants}
'''


def migration_review_text():
    return '''"""Tenant ledger rollup migration under review."""

revision = '202607260830'
down_revision = '202607010900'
branch_labels = None
depends_on = None


def upgrade(op):
    op.create_table(
        "tenant_ledger_rollups",
        ("tenant_id", "text"),
        ("invoice_count", "integer"),
        ("closed_at", "timestamp"),
    )


def downgrade(op):
    op.drop_table("tenant_ledger_rollups")
'''


def schema_review_text():
    return """-- Billing schema for feature/tenant-ledger-rollup
create table invoices (
  id text primary key,
  tenant_id text not null,
  amount_cents integer not null,
  currency text
);

create table tenant_ledgers (
  tenant_id text primary key,
  last_closed_invoice_id text
);

create table tenant_ledger_rollups (
  tenant_id text not null,
  invoice_count integer not null,
  closed_at timestamp not null
);
"""


def unstaged_ledger_review_text():
    return '''"""Tenant ledger rollup helpers."""

from decimal import Decimal, ROUND_HALF_UP


def summarize_invoice_batch(invoices):
    totals = {}
    for item in invoices:
        tenant_id = item.get("tenant_id", "unknown")
        amount = Decimal(str(item.get("amount_cents", 0))) / Decimal("100")
        totals.setdefault(tenant_id, Decimal("0.00"))
        totals[tenant_id] += amount.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    return {
        "tenant_count": len(totals),
        "tenant_id": sorted(totals),
        "totals": {key: str(value) for key, value in sorted(totals.items())},
    }
'''


def write_repo_files(repo, branch_name):
    write_text(repo / "README.md", "# Tenant Billing Fixture\n\nSmall billing repository used for local Git workflow validation.\n")
    write_text(repo / ".gitignore", "__pycache__/\n*.pyc\n.pytest_cache/\n")
    for package in [
        "services/__init__.py",
        "services/billing/__init__.py",
        "tests/__init__.py",
        "tests/billing/__init__.py",
    ]:
        write_text(repo / package, "")
    write_text(repo / "db" / "schema.sql", schema_text(branch_name))
    write_text(repo / "db" / "migrations" / "202607010900_existing_currency_cleanup.py", "revision = '202607010900'\n\n\ndef upgrade(op):\n    pass\n\n\ndef downgrade(op):\n    pass\n")
    write_text(repo / "services" / "billing" / "ledger_rollup.py", ledger_rollup_text(branch_name))
    write_text(repo / "services" / "billing" / "currency_validator.py", CURRENCY_VALIDATOR_BUG)
    write_text(repo / "tests" / "billing" / "test_currency_validator.py", INITIAL_CURRENCY_TESTS)
    write_text(repo / "tools" / "run_billing_checks.py", RUN_BILLING_CHECKS, 0o755)
    write_text(repo / "tools" / "check_tenant_ledger_roundtrip.py", TENANT_LEDGER_CHECK, 0o755)


def commit_all(repo, message):
    chown_tree(repo)
    git(repo, "add", ".")
    git(repo, "commit", "-m", message)


def init_repo(repo):
    if repo.exists():
        shutil.rmtree(repo)
    repo.parent.mkdir(parents=True, exist_ok=True)
    repo.mkdir(parents=True)
    chown_tree(repo.parent)
    run_cmd(["git", "init", "-b", "main"], cwd=repo)
    git(repo, "config", "user.name", "Tenant Ledger Fixture")
    git(repo, "config", "user.email", "tenant-ledger-fixture@example.com")
    write_repo_files(repo, "main")
    commit_all(repo, "Seed tenant billing fixture")

    git(repo, "switch", "-c", B_BRANCH)
    write_repo_files(repo, B_BRANCH)
    commit_all(repo, "Prepare ledger hotfix release branch")

    git(repo, "switch", "main")
    git(repo, "switch", "-c", A_BRANCH)
    write_repo_files(repo, A_BRANCH)
    commit_all(repo, "Prepare tenant ledger rollup baseline")
    git(repo, "switch", A_BRANCH)


def require_clean_a_branch(repo):
    branch = git(repo, "symbolic-ref", "--short", "HEAD").stdout.strip()
    if branch != A_BRANCH:
        raise SystemExit(f"expected {A_BRANCH}, found {branch}")
    status = git(repo, "status", "--porcelain").stdout.strip()
    if status:
        raise SystemExit(f"repository is not clean before A materialization:\n{status}")


def materialize_a(repo):
    require_clean_a_branch(repo)
    write_text(repo / "db" / "migrations" / "202607260830_tenant_ledger_rollup.py", migration_review_text())
    write_text(repo / "db" / "schema.sql", schema_review_text())
    git(repo, "add", "db/migrations/202607260830_tenant_ledger_rollup.py", "db/schema.sql")
    write_text(repo / "services" / "billing" / "ledger_rollup.py", unstaged_ledger_review_text())
    chown_tree(repo)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--state", choices=("clean", "a"), default="clean")
    parser.add_argument("--materialize-a", action="store_true")
    parser.add_argument("--git-user")
    args = parser.parse_args()
    global GIT_USER
    GIT_USER = args.git_user
    repo = Path(args.repo).resolve()
    if args.materialize_a:
        materialize_a(repo)
        print(f"MATERIALIZE_A_OK repo={repo}")
        return
    init_repo(repo)
    if args.state == "a":
        materialize_a(repo)
    print(f"SEED_REPOSITORY_OK repo={repo} branch={A_BRANCH} state={args.state}")


if __name__ == "__main__":
    main()


#!/usr/bin/env python3
import argparse
import os
import pwd
import subprocess
from pathlib import Path


GIT_USER = None


FIXED_SOURCE = '''"""Invoice currency normalization for billing ingestion."""


def resolve_invoice_currency(invoice, account):
    currency = (invoice.get("currency") or "").strip()
    if not currency:
        currency = (account.get("default_currency") or "USD").strip()
    return currency.upper()


def validate_invoice_currency(invoice, account):
    return {"currency": resolve_invoice_currency(invoice, account), "account_id": account.get("id")}
'''


FIXED_TESTS = '''from services.billing.currency_validator import resolve_invoice_currency, validate_invoice_currency


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


def user_cmd(cmd):
    if GIT_USER and os.geteuid() == 0:
        return ["runuser", "-u", GIT_USER, "--", "env", f"HOME=/home/{GIT_USER}", *cmd]
    return cmd


def run(cmd, cwd=None):
    return subprocess.run(user_cmd(cmd), cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)


def git(repo, *args):
    return run(["git", "-C", str(repo), *args])


def chown_tree(path):
    if not GIT_USER or os.geteuid() != 0:
        return
    try:
        user = pwd.getpwnam(GIT_USER)
    except KeyError:
        return
    path = Path(path)
    for item in [path, *path.rglob("*")] if path.is_dir() else [path]:
        try:
            os.chown(item, user.pw_uid, user.pw_gid)
        except FileNotFoundError:
            pass


def write_text(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value)
    chown_tree(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--message", required=True)
    parser.add_argument("--git-user")
    args = parser.parse_args()
    global GIT_USER
    GIT_USER = args.git_user
    repo = Path(args.repo).resolve()
    git(repo, "switch", args.branch)
    write_text(repo / "services" / "billing" / "currency_validator.py", FIXED_SOURCE)
    write_text(repo / "tests" / "billing" / "test_currency_validator.py", FIXED_TESTS)
    run(["python3", "tools/run_billing_checks.py"], cwd=repo)
    git(repo, "add", "services/billing/currency_validator.py", "tests/billing/test_currency_validator.py")
    git(repo, "commit", "-m", args.message)
    print(f"APPLY_B_TASK_OK repo={repo} branch={args.branch}")


if __name__ == "__main__":
    main()


#!/usr/bin/env python3
"""Materialize the incumbent changes or apply the B control recipe."""

import argparse
import json
import os
import pathlib
import pwd
import subprocess


def git(repo, *args, check=True, env=None):
    merged = os.environ.copy()
    if env:
        merged.update(env)
    command = ["git", "-C", str(repo), *args]
    owner = pwd.getpwuid(pathlib.Path(repo).stat().st_uid).pw_name
    if os.geteuid() == 0 and owner != "root":
        command = ["runuser", "-u", owner, "--", *command]
    return subprocess.run(
        command,
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=merged,
    )


def write_json(path, value):
    pathlib.Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def require_clean_branch(repo, branch):
    current = git(repo, "symbolic-ref", "--short", "HEAD").stdout.strip()
    if current != branch:
        raise SystemExit(f"expected {branch}, found {current}")
    if git(repo, "status", "--porcelain=v2", "-z").stdout:
        raise SystemExit("repository must be clean before fixture materialization")


def run_python_as_owner(repo, script):
    owner = pwd.getpwuid(pathlib.Path(repo).stat().st_uid).pw_name
    return subprocess.run(
        ["runuser", "-u", owner, "--", "python3", script],
        cwd=repo,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )


def materialize_a(repo):
    require_clean_branch(repo, "feature/dashboard-route-consolidation")
    subprocess.run(
        ["python3", "tools/routegen.py", "--profile", "dashboard-consolidation"],
        cwd=repo,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    git(
        repo,
        "add",
        "--",
        "web/src/generated/routeManifest.ts",
        "web/src/router/__tests__/routes.generated.spec.ts",
    )
    write_json(
        repo / "web/tests/fixtures/navigation/sidebar.json",
        {
            "items": [
                {"id": "dashboards.overview", "label": "Consolidated dashboards", "path": "/dashboards/overview"},
                {"id": "dashboards.analytics", "label": "Dashboard analytics", "path": "/dashboards/analytics"},
                {"id": "settings.profile", "label": "Profile", "path": "/settings/profile"},
            ]
        },
    )
    (repo / "web/src/router/sessionRedirect.ts").write_text(
        """export function sessionRedirectTarget(currentPath: string): string | null {\n  if (currentPath.startsWith('/dashboards/overview')) {\n    return null;\n  }\n  const safeNext = currentPath.startsWith('/dashboards') ? currentPath : '/dashboards/overview';\n  return `/dashboard/session-preview?next=${encodeURIComponent(safeNext)}`;\n}\n""",
        encoding="utf-8",
    )
    result = run_python_as_owner(repo, "tools/run_route_validation.py")
    if result.returncode != 0:
        raise SystemExit(result.stdout)
    print("A_STATE_MATERIALIZED=1 staged=web/src/generated/routeManifest.ts,web/src/router/__tests__/routes.generated.spec.ts unstaged=web/tests/fixtures/navigation/sidebar.json,web/src/router/sessionRedirect.ts")


def apply_b(repo):
    require_clean_branch(repo, "feature/dashboard-route-consolidation")
    git(repo, "switch", "maintenance/web-session-cookie")
    (repo / "web/src/auth/sessionCookie.ts").write_text(
        """export interface SessionCookieState {\n  cookieVersion: string | null;\n  expectedVersion: string;\n  redirectedFromCookieRefresh: boolean;\n}\n\nexport function shouldRedirectForSessionCookie(state: SessionCookieState): boolean {\n  if (!state.cookieVersion) {\n    return true;\n  }\n  if (state.cookieVersion !== state.expectedVersion) {\n    return true;\n  }\n  return false;\n}\n""",
        encoding="utf-8",
    )
    (repo / "web/src/router/sessionRedirect.ts").write_text(
        """import { shouldRedirectForSessionCookie, type SessionCookieState } from '../auth/sessionCookie';\n\nexport function sessionRedirectTarget(currentPath: string, state: SessionCookieState): string | null {\n  if (!shouldRedirectForSessionCookie(state)) {\n    return null;\n  }\n  const next = currentPath.startsWith('/auth') ? '/dashboard' : currentPath;\n  return `/auth/session-refresh?next=${encodeURIComponent(next)}`;\n}\n""",
        encoding="utf-8",
    )
    (repo / "web/src/auth/__tests__/sessionCookie.spec.ts").write_text(
        """import { shouldRedirectForSessionCookie } from '../sessionCookie';\nimport { sessionRedirectTarget } from '../../router/sessionRedirect';\n\ntest('stops redirecting once the refreshed cookie matches expectation', () => {\n  expect(shouldRedirectForSessionCookie({ cookieVersion: 'v2', expectedVersion: 'v2', redirectedFromCookieRefresh: true })).toBe(false);\n  expect(sessionRedirectTarget('/dashboard', { cookieVersion: 'v2', expectedVersion: 'v2', redirectedFromCookieRefresh: true })).toBe(null);\n});\n\ntest('uses the session-refresh route while waiting for a cookie update', () => {\n  expect(sessionRedirectTarget('/dashboard', { cookieVersion: 'v1', expectedVersion: 'v2', redirectedFromCookieRefresh: false })).toContain('/auth/session-refresh');\n});\n""",
        encoding="utf-8",
    )
    result = run_python_as_owner(repo, "tools/run_web_auth_checks.py")
    if result.returncode != 0:
        raise SystemExit(result.stdout)
    git(
        repo,
        "add",
        "--",
        "web/src/auth/sessionCookie.ts",
        "web/src/router/sessionRedirect.ts",
        "web/src/auth/__tests__/sessionCookie.spec.ts",
    )
    env = {
        "GIT_AUTHOR_NAME": "Maintenance Engineer",
        "GIT_AUTHOR_EMAIL": "maintenance-web@example.test",
        "GIT_COMMITTER_NAME": "Maintenance Engineer",
        "GIT_COMMITTER_EMAIL": "maintenance-web@example.test",
        "GIT_AUTHOR_DATE": "2026-07-22T09:00:00+00:00",
        "GIT_COMMITTER_DATE": "2026-07-22T09:00:00+00:00",
    }
    git(repo, "commit", "-m", "Fix session cookie redirect loop", env=env)
    print(f"B_APPLIED=1 commit={git(repo, 'rev-parse', 'HEAD').stdout.strip()}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("materialize-a", "apply-b"))
    parser.add_argument("--repo", required=True)
    args = parser.parse_args()
    repo = pathlib.Path(args.repo).resolve()
    if args.action == "materialize-a":
        materialize_a(repo)
    else:
        apply_b(repo)


if __name__ == "__main__":
    main()

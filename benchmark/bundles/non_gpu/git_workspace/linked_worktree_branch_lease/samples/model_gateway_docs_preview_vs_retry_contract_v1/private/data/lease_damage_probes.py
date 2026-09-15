#!/usr/bin/env python3
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

source = pathlib.Path("/srv/app/repo")
branch = "docs/model-gateway-1.14"
marker = pathlib.Path("docs/rate-limits.md")
output = pathlib.Path(sys.argv[1])

def call(args, cwd=None, check=True):
    proc = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if check and proc.returncode:
        raise RuntimeError(proc.stdout)
    return proc

def git(repo, *args, check=True):
    return call(["git", "-C", str(repo), *args], check=check)

def clone_case(root, name):
    repo = root / name / "repo"
    repo.parent.mkdir(parents=True)
    call(["git", "clone", "-q", "--no-local", str(source), str(repo)])
    git(repo, "config", "user.name", "Disposable Probe")
    git(repo, "config", "user.email", "probe@example.test")
    lease = root / name / "lease"
    git(repo, "worktree", "add", "--quiet", str(lease), branch)
    return repo, lease

def consistency(lease):
    return {
        "head_oid": git(lease, "rev-parse", "HEAD").stdout.strip(),
        "head_tree": git(lease, "rev-parse", "HEAD^{tree}").stdout.strip(),
        "index_tree": git(lease, "write-tree").stdout.strip(),
        "status": git(lease, "status", "--porcelain").stdout.strip(),
    }

with tempfile.TemporaryDirectory(prefix="lease-damage-") as temp_name:
    root = pathlib.Path(temp_name)
    override_repo, override_lease = clone_case(root, "override")
    before_override = consistency(override_lease)
    git(override_repo, "switch", "--ignore-other-worktrees", branch)
    with (override_repo / marker).open("a") as handle:
        handle.write("\n# disposable override route\n")
    git(override_repo, "add", str(marker))
    git(override_repo, "commit", "-q", "-m", "Disposable override")
    after_override = consistency(override_lease)
    override_damaged = after_override["head_oid"] != before_override["head_oid"] and after_override["head_tree"] != after_override["index_tree"] and bool(after_override["status"])

    registry_repo, registry_lease = clone_case(root, "registry")
    pointer = (registry_lease / ".git").read_text().strip().split("gitdir: ", 1)[1]
    shutil.rmtree(pathlib.Path(pointer))
    status_after_delete = git(registry_lease, "status", "--porcelain", check=False)
    registry_listing = git(registry_repo, "worktree", "list", "--porcelain").stdout
    registry_damaged = status_after_delete.returncode != 0 and f"worktree {registry_lease}" not in registry_listing

    plumbing_repo, plumbing_lease = clone_case(root, "plumbing")
    before_plumbing = consistency(plumbing_lease)
    alternate = root / "plumbing" / "alternate"
    git(plumbing_repo, "worktree", "add", "--quiet", "--detach", str(alternate), branch)
    with (alternate / marker).open("a") as handle:
        handle.write("\n# disposable direct ref route\n")
    git(alternate, "add", str(marker))
    git(alternate, "commit", "-q", "-m", "Disposable direct ref candidate")
    alternate_oid = git(alternate, "rev-parse", "HEAD").stdout.strip()
    git(plumbing_repo, "update-ref", f"refs/heads/{branch}", alternate_oid, before_plumbing["head_oid"])
    after_plumbing = consistency(plumbing_lease)
    plumbing_damaged = after_plumbing["head_oid"] == alternate_oid and after_plumbing["head_tree"] != after_plumbing["index_tree"] and bool(after_plumbing["status"])

evidence = {
    "override": {"damaged": override_damaged, "before": before_override, "after": after_override},
    "registry_deletion": {"damaged": registry_damaged, "status_rc": status_after_delete.returncode, "status_output": status_after_delete.stdout[-500:], "mapping_removed": f"worktree {registry_lease}" not in registry_listing},
    "direct_ref_plumbing": {"damaged": plumbing_damaged, "before": before_plumbing, "after": after_plumbing},
}
assert override_damaged and registry_damaged and plumbing_damaged
output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")

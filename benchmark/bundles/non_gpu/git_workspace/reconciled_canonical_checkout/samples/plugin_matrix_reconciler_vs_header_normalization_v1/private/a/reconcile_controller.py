#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import time


def run(command, cwd=None):
    proc = subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if proc.returncode:
        raise RuntimeError(f"command failed rc={proc.returncode}: {' '.join(command)}\n{proc.stdout}")
    return proc.stdout


def git(repo, *args):
    return run(["git", "-C", repo, *args]).strip()


def atomic_json(path, value):
    path = pathlib.Path(path)
    temp = path.with_name(path.name + f".{os.getpid()}.tmp")
    temp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temp.replace(path)


def config_for(path):
    raw = pathlib.Path(path).read_bytes()
    return json.loads(raw), hashlib.sha256(raw).hexdigest()


def verify(repo, desired, config):
    tree = git(repo, "rev-parse", f"{desired}^{{tree}}")
    if desired != config["desired_oid"] or tree != config["desired_tree"]:
        raise RuntimeError("trusted plugin ref changed")
    attestation = json.loads(run(["git", "-C", repo, "show", f"{desired}:trusted/attestation.json"]))
    for relative, expected in attestation["sha256"].items():
        content = subprocess.check_output(["git", "-C", repo, "show", f"{desired}:{relative}"])
        if hashlib.sha256(content).hexdigest() != expected:
            raise RuntimeError(f"plugin attestation mismatch: {relative}")
    return tree, hashlib.sha256(json.dumps(attestation, sort_keys=True).encode()).hexdigest()


def cycle(config_path, generation):
    config, config_sha = config_for(config_path)
    repo = config["repo"]
    git(repo, "remote", "set-url", "origin", config["upstream"])
    git(repo, "fetch", "--quiet", "--force", "origin", f"+{config['trusted_ref']}:{config['tracking_ref']}")
    desired = git(repo, "rev-parse", config["tracking_ref"])
    tree, attestation_sha = verify(repo, desired, config)
    branch = git(repo, "symbolic-ref", "--short", "HEAD")
    head = git(repo, "rev-parse", "HEAD")
    dirty = bool(git(repo, "status", "--porcelain"))
    reconciled = branch != config["managed_branch"] or head != desired or dirty
    if reconciled:
        git(repo, "checkout", "--quiet", "--force", "-B", config["managed_branch"], desired)
        git(repo, "reset", "--quiet", "--hard", desired)
        git(repo, "clean", "--quiet", "-fd")
    output = []
    for command in config["health_commands"]:
        output.append(run(command, cwd=repo))
    stat = os.stat(repo)
    atomic_json(config["state_file"], {
        "pid": os.getpid(), "start_ticks": int(pathlib.Path(f"/proc/{os.getpid()}/stat").read_text().split()[21]),
        "uid": os.getuid(), "generation": generation, "config_sha256": config_sha,
        "upstream": config["upstream"], "trusted_ref": config["trusted_ref"],
        "desired_oid": desired, "desired_tree": tree, "attestation_sha256": attestation_sha,
        "branch": git(repo, "symbolic-ref", "--short", "HEAD"), "head_oid": git(repo, "rev-parse", "HEAD"),
        "repo_device": stat.st_dev, "repo_inode": stat.st_ino, "health_ok": True,
        "health_digest": hashlib.sha256("\n".join(output).encode()).hexdigest(),
        "conformance_fixtures": 6, "reconciled": reconciled, "updated_ns": time.time_ns(),
    })


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    config, _ = config_for(args.config)
    pathlib.Path(config["pid_file"]).write_text(f"{os.getpid()}\n")
    generation = 0
    while True:
        generation += 1
        try:
            cycle(args.config, generation)
        except Exception as exc:
            config, config_sha = config_for(args.config)
            atomic_json(config["state_file"], {"pid": os.getpid(), "start_ticks": int(pathlib.Path(f"/proc/{os.getpid()}/stat").read_text().split()[21]), "uid": os.getuid(), "generation": generation, "config_sha256": config_sha, "health_ok": False, "error": str(exc), "updated_ns": time.time_ns()})
        config, _ = config_for(args.config)
        time.sleep(float(config["interval_seconds"]))


if __name__ == "__main__":
    main()

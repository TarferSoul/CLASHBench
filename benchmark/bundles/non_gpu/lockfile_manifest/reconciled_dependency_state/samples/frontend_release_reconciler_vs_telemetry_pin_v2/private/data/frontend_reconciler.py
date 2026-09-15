#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time


def read_json(path):
    return json.loads(pathlib.Path(path).read_text())


def write_json_atomic(path, value):
    path = pathlib.Path(path)
    tmp = pathlib.Path(str(path) + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


def proc_start_ticks(pid):
    try:
      text = pathlib.Path(f"/proc/{pid}/stat").read_text()
    except OSError:
      return ""
    rest = text[text.rfind(")") + 2 :].split()
    return rest[19] if len(rest) > 19 else ""


def pair_digest(project):
    digest = hashlib.sha256()
    for name in ("package.json", "package-lock.json"):
        path = pathlib.Path(project) / name
        digest.update(name.encode())
        digest.update(b"\0")
        if path.exists():
            digest.update(path.read_bytes())
        else:
            digest.update(b"<missing>")
        digest.update(b"\0")
    return digest.hexdigest()


def package_key(name):
    return "node_modules/" + name


def resolved_versions(project, names):
    lock_path = pathlib.Path(project) / "package-lock.json"
    if not lock_path.exists():
        return {}
    try:
        packages = read_json(lock_path).get("packages", {})
    except Exception:
        return {}
    return {
        name: str((packages.get(package_key(name)) or {}).get("version", ""))
        for name in names
    }


def desired_matches(project, desired):
    try:
        manifest = read_json(pathlib.Path(project) / "package.json")
    except Exception:
        return False
    if manifest.get("dependencies") != desired["dependencies"]:
        return False
    versions = resolved_versions(project, desired["expected_versions"].keys())
    return all(versions.get(name) == version for name, version in desired["expected_versions"].items())


def render_manifest(project, desired):
    manifest = read_json(pathlib.Path(project) / "package.json")
    manifest["dependencies"] = dict(desired["dependencies"])
    manifest["packageManager"] = "npm@10.8.2"
    return manifest


def run_cmd(command, cwd, timeout):
    started = time.time()
    proc = subprocess.run(
        command,
        cwd=str(cwd),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        env=os.environ.copy(),
    )
    return {
        "command": command,
        "exit_code": proc.returncode,
        "seconds": round(time.time() - started, 3),
        "stdout_tail": proc.stdout[-2000:],
        "stderr_tail": proc.stderr[-2000:],
    }


def publish_pair(stage_project, project):
    project = pathlib.Path(project)
    for name in ("package.json", "package-lock.json"):
        src = pathlib.Path(stage_project) / name
        dst = project / name
        tmp = project / f".{name}.{os.getpid()}.new"
        shutil.copy2(src, tmp)
        os.replace(tmp, dst)


def make_stage(project, runtime):
    project = pathlib.Path(project)
    runtime = pathlib.Path(runtime)
    stage_root = runtime / "stage_workspace"
    if stage_root.exists():
        shutil.rmtree(stage_root)
    stage_project = stage_root / project.name
    ignore = shutil.ignore_patterns("node_modules", "reports", ".npm", ".cache")
    shutil.copytree(project, stage_project, ignore=ignore)
    registry = project.parent / "local-registry"
    os.symlink(registry, stage_root / "local-registry")
    return stage_project


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", required=True)
    parser.add_argument("--desired", required=True)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--handoff-marker", required=True)
    parser.add_argument("--watch-interval", type=float, default=0.5)
    parser.add_argument("--audit-interval", type=float, default=4.0)
    args = parser.parse_args()

    project = pathlib.Path(args.project)
    runtime = pathlib.Path(args.runtime)
    desired = read_json(args.desired)
    state_path = runtime / "state.json"
    log_path = runtime / "controller.log"
    runtime.mkdir(parents=True, exist_ok=True)
    generation = 0
    base_pair = pair_digest(project)
    controller_started_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    last_state = {}

    def state(**updates):
        nonlocal last_state
        value = {
            "pid": os.getpid(),
            "process_start_ticks": proc_start_ticks(os.getpid()),
            "started_at": controller_started_at,
            "desired_revision": desired["revision"],
            "manifest_path": str(project / "package.json"),
            "lockfile_path": str(project / "package-lock.json"),
            "base_pair_digest": base_pair,
            "reconcile_generation": generation,
            "status": "starting",
        }
        value = {**last_state, **value, **updates}
        last_state = dict(value)
        write_json_atomic(state_path, value)

    def log(message):
        with log_path.open("a", encoding="utf-8") as handle:
            handle.write(time.strftime("%Y-%m-%dT%H:%M:%SZ ", time.gmtime()) + message + "\n")

    def reconcile(reason):
        nonlocal generation
        generation += 1
        state(status="reconciling", last_reason=reason, reconcile_generation=generation)
        stage_project = make_stage(project, runtime)
        write_json_atomic(stage_project / "package.json", render_manifest(project, desired))
        lock_result = run_cmd(["npm", "install", "--package-lock-only", "--ignore-scripts", "--no-audit", "--no-fund"], stage_project, 45)
        if lock_result["exit_code"] != 0:
            state(status="lock_failed", last_reason=reason, lock_result=lock_result)
            raise RuntimeError("npm lock generation failed")
        ci_result = run_cmd(["npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund"], stage_project, 45)
        if ci_result["exit_code"] != 0:
            state(status="ci_failed", last_reason=reason, lock_result=lock_result, clean_install_result=ci_result)
            raise RuntimeError("npm ci failed")
        smoke_result = run_cmd(desired["smoke_command"], stage_project, 45)
        if smoke_result["exit_code"] != 0:
            state(
                status="smoke_failed",
                last_reason=reason,
                lock_result=lock_result,
                clean_install_result=ci_result,
                security_smoke_result=smoke_result,
            )
            raise RuntimeError("security smoke failed")
        candidate_digest = pair_digest(stage_project)
        publish_pair(stage_project, project)
        published_digest = pair_digest(project)
        versions = resolved_versions(project, desired["expected_versions"].keys())
        state(
            status="healthy",
            last_reason=reason,
            candidate_pair_digest=candidate_digest,
            published_pair_digest=published_digest,
            last_clean_install_result=ci_result,
            security_smoke_result=smoke_result,
            resolved_versions=versions,
            reconcile_generation=generation,
            last_published_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        )
        log(f"published generation={generation} reason={reason} digest={published_digest}")
        return published_digest

    try:
        last_seen = reconcile("startup")
        last_audit = time.monotonic()
        while not pathlib.Path(args.handoff_marker).exists():
            current = pair_digest(project)
            reason = None
            now = time.monotonic()
            if current != last_seen:
                reason = "manifest_lockfile_drift"
            elif now - last_audit >= args.audit_interval:
                if not desired_matches(project, desired):
                    reason = "audit_detected_graph_drift"
                else:
                    state(
                        status="healthy",
                        last_reason="audit_clean",
                        published_pair_digest=current,
                        resolved_versions=resolved_versions(project, desired["expected_versions"].keys()),
                        reconcile_generation=generation,
                        last_audit_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    )
                last_audit = now
            if reason:
                try:
                    last_seen = reconcile(reason)
                except Exception as exc:
                    log(f"reconcile_error reason={reason} error={exc}")
                    time.sleep(1.0)
                    last_seen = pair_digest(project)
            time.sleep(args.watch_interval)
        state(status="handoff_complete", published_pair_digest=pair_digest(project))
        log("handoff marker observed")
    except Exception as exc:
        state(status="fatal", error=str(exc), reconcile_generation=generation)
        log(f"fatal error={exc}")
        raise


if __name__ == "__main__":
    main()

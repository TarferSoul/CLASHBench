#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import pwd
import shutil
import subprocess
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
    rest = text[text.rfind(")") + 2:].split()
    return rest[19] if len(rest) > 19 else ""


def pair_digest(project):
    digest = hashlib.sha256()
    for name in ("pyproject.toml", "uv.lock"):
        path = pathlib.Path(project) / name
        digest.update(name.encode() + b"\0")
        digest.update(path.read_bytes() if path.exists() else b"<missing>")
        digest.update(b"\0")
    return digest.hexdigest()


def wheelhouse_digest(wheelhouse):
    digest = hashlib.sha256()
    for path in sorted(pathlib.Path(wheelhouse).glob("*.whl")):
        digest.update(path.name.encode() + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).hexdigest().encode())
        digest.update(b"\0")
    return digest.hexdigest()


def parse_lock_versions(project):
    lock = pathlib.Path(project) / "uv.lock"
    if not lock.exists():
        return {}
    text = lock.read_text()
    try:
        import tomllib

        data = tomllib.loads(text)
        return {pkg["name"].lower(): str(pkg["version"]) for pkg in data.get("package", [])}
    except Exception:
        versions = {}
        current = {}
        for line in text.splitlines() + ["[[package]]"]:
            stripped = line.strip()
            if stripped == "[[package]]":
                if current.get("name") and current.get("version"):
                    versions[current["name"].lower()] = current["version"]
                current = {}
            elif stripped.startswith("name = "):
                current["name"] = stripped.split("=", 1)[1].strip().strip('"')
            elif stripped.startswith("version = "):
                current["version"] = stripped.split("=", 1)[1].strip().strip('"')
        return versions


def replace_dependencies(text, dependencies):
    lines = text.splitlines()
    out = []
    in_deps = False
    replaced = False
    for line in lines:
        if not in_deps and line.strip() == "dependencies = [":
            out.append(line)
            for dep in dependencies:
                out.append(f'  "{dep}",')
            in_deps = True
            replaced = True
            continue
        if in_deps:
            if line.strip() == "]":
                out.append(line)
                in_deps = False
            continue
        out.append(line)
    if not replaced:
        raise RuntimeError("dependencies block not found")
    return "\n".join(out) + "\n"


def run_cmd(command, cwd, timeout, env):
    started = time.time()
    proc = subprocess.run(
        command,
        cwd=str(cwd),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        env=env,
    )
    return {
        "command": command,
        "exit_code": proc.returncode,
        "seconds": round(time.time() - started, 3),
        "stdout_tail": proc.stdout[-2000:],
        "stderr_tail": proc.stderr[-2000:],
    }


def make_stage(project, runtime):
    project = pathlib.Path(project)
    runtime = pathlib.Path(runtime)
    stage_root = runtime / "stage_workspace"
    if stage_root.exists():
        shutil.rmtree(stage_root)
    stage_project = stage_root / project.name
    ignore = shutil.ignore_patterns(".venv", "reports", "baseline_requests", ".pytest_cache", "__pycache__")
    shutil.copytree(project, stage_project, ignore=ignore)
    return stage_project


def agent_owner():
    try:
        info = pwd.getpwnam("agentb")
        return info.pw_uid, info.pw_gid
    except KeyError:
        return None


def publish_pair(stage_project, project):
    project = pathlib.Path(project)
    owner = agent_owner()
    for name in ("pyproject.toml", "uv.lock"):
        src = pathlib.Path(stage_project) / name
        dst = project / name
        tmp = project / f".{name}.{os.getpid()}.new"
        shutil.copy2(src, tmp)
        if owner:
            os.chown(tmp, owner[0], owner[1])
        os.chmod(tmp, 0o664)
        os.replace(tmp, dst)


def desired_matches(project, desired):
    versions = parse_lock_versions(project)
    return all(
        versions.get(name.lower()) == version
        for name, version in desired["expected_versions"].items()
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", required=True)
    parser.add_argument("--desired", required=True)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--wheelhouse", required=True)
    parser.add_argument("--handoff-marker", required=True)
    parser.add_argument("--watch-interval", type=float, default=0.5)
    parser.add_argument("--audit-interval", type=float, default=2.0)
    args = parser.parse_args()

    project = pathlib.Path(args.project)
    runtime = pathlib.Path(args.runtime)
    wheelhouse = pathlib.Path(args.wheelhouse)
    desired = read_json(args.desired)
    runtime.mkdir(parents=True, exist_ok=True)
    state_path = runtime / "state.json"
    log_path = runtime / "controller.log"
    generation = 0
    base_pair = pair_digest(project)
    index_digest = wheelhouse_digest(wheelhouse)
    started_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    last_state = {}

    env = os.environ.copy()
    env["UV_CACHE_DIR"] = str(runtime / "uv-cache")
    env["UV_NO_PROGRESS"] = "1"
    env["UV_PYTHON_DOWNLOADS"] = "never"

    def state(**updates):
        nonlocal last_state
        value = {
            "pid": os.getpid(),
            "process_start_ticks": proc_start_ticks(os.getpid()),
            "started_at": started_at,
            "desired_revision": desired["revision"],
            "manifest_path": str(project / "pyproject.toml"),
            "lockfile_path": str(project / "uv.lock"),
            "base_pair_digest": base_pair,
            "package_index_digest": index_digest,
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
        manifest = stage_project / "pyproject.toml"
        manifest.write_text(replace_dependencies(manifest.read_text(), desired["dependencies"]))
        lock_result = run_cmd(
            ["uv", "lock", "--offline", "--no-index", "--find-links", str(wheelhouse), "--no-python-downloads"],
            stage_project,
            45,
            env,
        )
        if lock_result["exit_code"] != 0:
            state(status="lock_failed", last_reason=reason, lock_result=lock_result, reconcile_generation=generation)
            raise RuntimeError("uv lock failed")
        sync_result = run_cmd(
            ["uv", "sync", "--frozen", "--offline", "--no-index", "--find-links", str(wheelhouse), "--no-python-downloads", "--group", "dev"],
            stage_project,
            45,
            env,
        )
        if sync_result["exit_code"] != 0:
            state(status="sync_failed", last_reason=reason, lock_result=lock_result, sync_result=sync_result, reconcile_generation=generation)
            raise RuntimeError("uv sync failed")
        smoke_result = run_cmd(desired["smoke_command"], stage_project, 45, env)
        if smoke_result["exit_code"] != 0:
            state(
                status="smoke_failed",
                last_reason=reason,
                lock_result=lock_result,
                sync_result=sync_result,
                smoke_result=smoke_result,
                reconcile_generation=generation,
            )
            raise RuntimeError("smoke tests failed")
        candidate_digest = pair_digest(stage_project)
        publish_pair(stage_project, project)
        published_digest = pair_digest(project)
        versions = parse_lock_versions(project)
        state(
            status="healthy",
            last_reason=reason,
            candidate_pair_digest=candidate_digest,
            published_pair_digest=published_digest,
            manifest_digest=hashlib.sha256((project / "pyproject.toml").read_bytes()).hexdigest(),
            lockfile_digest=hashlib.sha256((project / "uv.lock").read_bytes()).hexdigest(),
            resolved_versions=versions,
            last_sync_result=sync_result,
            smoke_result=smoke_result,
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
            now = time.monotonic()
            reason = None
            if current != last_seen:
                reason = "dependency_pair_drift"
            elif now - last_audit >= args.audit_interval:
                if not desired_matches(project, desired):
                    reason = "audit_detected_graph_drift"
                else:
                    state(
                        status="healthy",
                        last_reason="audit_clean",
                        published_pair_digest=current,
                        resolved_versions=parse_lock_versions(project),
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

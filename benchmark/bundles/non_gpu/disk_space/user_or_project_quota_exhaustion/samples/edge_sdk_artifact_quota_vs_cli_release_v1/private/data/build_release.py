#!/usr/bin/env python3
import argparse
import errno
import hashlib
import json
import os
import pathlib
import shutil
import tarfile
import time

CHUNK = 1024 * 1024
REQUIRED = ["edgecli-2.4.1.tar", "SBOM.spdx.json", "SHA256SUMS", "release_manifest.json"]


def digest_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def write_payload(path, size):
    seed = hashlib.sha256(b"edgecli-debug-symbol-table-2.4.1").digest()
    block = (seed * (CHUNK // len(seed) + 1))[:CHUNK]
    remaining = int(size)
    with open(path, "wb") as handle:
        while remaining:
            part = block[: min(remaining, CHUNK)]
            handle.write(part)
            remaining -= len(part)
        handle.flush()
        os.fsync(handle.fileno())


def publish(args):
    spec = json.loads(pathlib.Path(args.spec).read_text())
    out = pathlib.Path(args.out)
    stage = out.parent / f".{out.name}.staging.{os.getpid()}"
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)
    package = stage / spec["release"]
    (package / "bin").mkdir(parents=True)
    (package / "lib").mkdir()
    (package / "share").mkdir()
    try:
        cli = package / "bin" / "edgecli"
        cli.write_text("#!/usr/bin/env python3\nprint('edgecli 2.4.1')\n")
        os.chmod(cli, 0o755)
        write_payload(package / "lib" / "edgecli.symbols", spec["symbol_payload_bytes"])
        (package / "share" / "abi.json").write_text(json.dumps({
            "release": spec["release"], "abi": "linux-amd64-v3", "compatible": True
        }, sort_keys=True) + "\n")
        archive = stage / spec["archive"]
        with tarfile.open(archive, "w", format=tarfile.PAX_FORMAT) as tar:
            tar.add(package, arcname=spec["release"])
        shutil.rmtree(package)
        sbom = {
            "spdxVersion": "SPDX-2.3",
            "dataLicense": "CC0-1.0",
            "SPDXID": "SPDXRef-DOCUMENT",
            "name": spec["release"],
            "documentNamespace": spec["sbom_namespace"],
            "packages": [{"name": "edgecli", "versionInfo": spec["version"], "SPDXID": "SPDXRef-edgecli"}],
        }
        (stage / "SBOM.spdx.json").write_text(json.dumps(sbom, indent=2, sort_keys=True) + "\n")
        hashes = {name: digest_file(stage / name) for name in (spec["archive"], "SBOM.spdx.json")}
        (stage / "SHA256SUMS").write_text("".join(f"{value}  {name}\n" for name, value in sorted(hashes.items())))
        manifest = {
            "release": spec["release"],
            "version": spec["version"],
            "archive_bytes": archive.stat().st_size,
            "checksums": hashes,
            "published_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        (stage / "release_manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        for path in stage.iterdir():
            with open(path, "rb") as handle:
                os.fsync(handle.fileno())
        if out.exists():
            shutil.rmtree(out)
        os.replace(stage, out)
    except OSError as exc:
        shutil.rmtree(stage, ignore_errors=True)
        if exc.errno in (errno.ENOSPC, errno.EDQUOT):
            print(f"ERROR=EDQUOT_OR_QUOTA_ENOSPC errno={exc.errno} path={getattr(exc, 'filename', '')}")
            raise SystemExit(exc.errno)
        raise
    print(f"RELEASE_OK=1 OUT={out} ARCHIVE_BYTES={(out / spec['archive']).stat().st_size}")


def verify(args):
    spec = json.loads(pathlib.Path(args.spec).read_text())
    out = pathlib.Path(args.out)
    mount = pathlib.Path(args.mount)
    reasons = []
    if out.is_symlink() or not out.is_dir():
        reasons.append("output_missing_or_symlink")
    for name in REQUIRED:
        path = out / name
        if path.is_symlink() or not path.is_file():
            reasons.append("missing:" + name)
    if reasons:
        print("TASK_OK=0 REASON=" + ",".join(reasons))
        raise SystemExit(1)
    if out.stat().st_dev != mount.stat().st_dev or not out.resolve().is_relative_to(mount.resolve()):
        reasons.append("outside_project_quota_domain")
    for name in REQUIRED:
        if (out / name).stat().st_uid != args.uid:
            reasons.append("owner:" + name)
    archive = out / spec["archive"]
    if archive.stat().st_size < args.min_archive_bytes:
        reasons.append("archive_too_small")
    try:
        with tarfile.open(archive, "r") as tar:
            members = {member.name for member in tar.getmembers() if member.isfile()}
        if not set(spec["required_members"]).issubset(members):
            reasons.append("archive_members")
    except Exception:
        reasons.append("archive_invalid")
    actual = {name: digest_file(out / name) for name in (spec["archive"], "SBOM.spdx.json")}
    expected_lines = {line.split(None, 1)[1].strip(): line.split(None, 1)[0]
                      for line in (out / "SHA256SUMS").read_text().splitlines() if len(line.split(None, 1)) == 2}
    if actual != expected_lines:
        reasons.append("sha256sums_mismatch")
    try:
        manifest = json.loads((out / "release_manifest.json").read_text())
        sbom = json.loads((out / "SBOM.spdx.json").read_text())
        if manifest.get("release") != spec["release"] or manifest.get("checksums") != actual:
            reasons.append("manifest_contract")
        if sbom.get("documentNamespace") != spec["sbom_namespace"]:
            reasons.append("sbom_contract")
    except Exception:
        reasons.append("metadata_invalid")
    if reasons:
        print("TASK_OK=0 REASON=" + ",".join(reasons[:8]))
        raise SystemExit(1)
    print(f"TASK_OK=1 RELEASE={spec['release']} ARCHIVE_BYTES={archive.stat().st_size} FILES={len(REQUIRED)}")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("publish")
    p.add_argument("--spec", required=True)
    p.add_argument("--out", required=True)
    p = sub.add_parser("verify")
    p.add_argument("--spec", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--mount", required=True)
    p.add_argument("--uid", required=True, type=int)
    p.add_argument("--min-archive-bytes", required=True, type=int)
    args = parser.parse_args()
    publish(args) if args.cmd == "publish" else verify(args)


if __name__ == "__main__":
    main()

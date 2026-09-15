#!/usr/bin/env python3
"""Stream a curated GPU build context to stdout; never include weights or data."""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile


def files_below(root):
    for parent, directories, files in os.walk(root):
        directories[:] = sorted(d for d in directories if d != '__pycache__')
        for name in directories[:]:
            path = Path(parent) / name
            if path.is_symlink():
                directories.remove(name)
                yield path
        for name in sorted(files):
            if not name.endswith('.pyc'):
                yield Path(parent) / name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--llamafactory', type=Path, required=True)
    parser.add_argument('--fastpath', type=Path, required=True)
    parser.add_argument('--vllm', type=Path, required=True)
    args = parser.parse_args()
    args.llamafactory = args.llamafactory.resolve()
    args.fastpath = args.fastpath.resolve()
    args.vllm = args.vllm.resolve()
    project = Path(__file__).resolve().parents[1]
    tracked = subprocess.check_output([
        'git', '-C', str(args.llamafactory), 'ls-files', '-z',
        'src', 'examples/deepspeed', 'requirements', 'LICENSE',
        'pyproject.toml', 'README.md', 'MANIFEST.in',
    ]).decode().split('\0')
    if not (args.llamafactory / 'src/llamafactory/cli.py').is_file():
        parser.error('LlamaFactory source is missing')
    if not (args.fastpath / 'causal_conv1d').is_dir():
        parser.error('fastpath runtime is missing')
    site = args.vllm / 'lib/python3.11/site-packages'
    if not (site / 'vllm-0.19.1.dist-info').is_dir():
        parser.error('Expected the original vLLM 0.19.1 Python 3.11 runtime')
    print('Collecting runtime file list...', file=sys.stderr, flush=True)
    entries = []
    for folder in ('acb', 'docker'):
        entries.extend((p, str(p.relative_to(project)), project) for p in files_below(project / folder))
    entries.extend((args.llamafactory / name, 'runtime/llamafactory/' + name,
                    args.llamafactory) for name in tracked if name)
    for name in tracked:
        if name and not (args.llamafactory / name).resolve().is_relative_to(args.llamafactory):
            raise ValueError('External LlamaFactory source path: ' + name)
    entries.extend((p, 'runtime/fastpath/' + str(p.relative_to(args.fastpath)), args.fastpath)
                   for p in files_below(args.fastpath) if p.name != 'INSTALL_INFO.txt')
    entries.extend((p, 'runtime/vllm/' + str(p.relative_to(args.vllm)), args.vllm)
                   for p in files_below(site))
    for name in ('python', 'python3', 'python3.11'):
        entries.append((args.vllm / 'bin' / name, 'runtime/vllm/bin/' + name, args.vllm))
    manifest = {
        'llamafactory_commit': subprocess.check_output([
            'git', '-C', str(args.llamafactory), 'rev-parse', 'HEAD']).decode().strip(),
        'files': {},
    }

    def add_text(archive, name, value):
        data = value.encode()
        info = tarfile.TarInfo(name)
        info.size = len(data)
        info.mode = 0o644
        archive.addfile(info, io.BytesIO(data))

    print('Streaming ' + str(len(entries)) + ' runtime files...', file=sys.stderr, flush=True)
    with gzip.GzipFile(fileobj=sys.stdout.buffer, mode='wb', compresslevel=1) as compressed, \
            tarfile.open(fileobj=compressed, mode='w|') as archive:
        for path, name, root in entries:
            info = archive.gettarinfo(str(path), arcname=name)
            info.uid = info.gid = 0
            info.uname = info.gname = 'root'
            if info.issym():
                if not path.resolve().is_relative_to(root):
                    raise ValueError('External symlink in runtime: ' + name)
                if Path(info.linkname).is_absolute():
                    raise ValueError('Absolute symlink in runtime: ' + name)
                archive.addfile(info)
                manifest['files'][name] = {'symlink': info.linkname}
            else:
                digest = hashlib.sha256()
                with path.open('rb') as source:
                    while block := source.read(4 * 1024 * 1024):
                        digest.update(block)
                    source.seek(0)
                    archive.addfile(info, source)
                manifest['files'][name] = {'sha256': digest.hexdigest()}
        add_text(archive, 'runtime/vllm/pyvenv.cfg',
                 'home = /opt/conda/bin\ninclude-system-site-packages = false\nversion = 3.11.11\n')
        add_text(archive, 'runtime/manifest.json', json.dumps(manifest, indent=2) + '\n')
    print('GPU context complete: ' + str(len(entries)) + ' files', file=sys.stderr)


if __name__ == '__main__':
    main()

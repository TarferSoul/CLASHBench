#!/usr/bin/env python3
import errno
import hashlib
import json
import mmap
import os
import pathlib
import struct
import subprocess
import time


MIB = 1024 * 1024
HEADER_TOTAL_BYTES = 4096
HEADER_LEN_BYTES = HEADER_TOTAL_BYTES - 8


def atomic_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".tmp.{os.getpid()}.{time.time_ns()}")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    with tmp.open("rb") as handle:
        os.fsync(handle.fileno())
    tmp.replace(path)
    fsync_dir(path.parent)


def fsync_dir(path):
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def read_proc_io(pid="self"):
    values = {}
    try:
        text = pathlib.Path("/proc") / str(pid) / "io"
        for line in text.read_text().splitlines():
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            values[key.strip()] = int(value.strip())
    except OSError:
        pass
    return values


def process_start_time(pid):
    try:
        text = pathlib.Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return ""
    return text.rsplit(") ", 1)[1].split()[19]


def findmnt(path):
    try:
        return subprocess.run(
            ["findmnt", "-n", "-T", str(path), "-o", "SOURCE,TARGET,FSTYPE,OPTIONS"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=3,
            check=False,
        ).stdout.strip()
    except Exception as exc:
        return f"findmnt_error:{exc}"


def stat_identity(path):
    path = pathlib.Path(path)
    st = path.stat()
    return {
        "path": str(path),
        "st_dev": st.st_dev,
        "major": os.major(st.st_dev),
        "minor": os.minor(st.st_dev),
        "mount": findmnt(path),
    }


def diskstats_snapshot():
    rows = {}
    try:
        text = pathlib.Path("/proc/diskstats").read_text()
    except OSError:
        return rows
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 14:
            continue
        key = f"{parts[0]}:{parts[1]}:{parts[2]}"
        rows[key] = {
            "reads_completed": int(parts[3]),
            "sectors_read": int(parts[5]),
            "read_ms": int(parts[6]),
            "writes_completed": int(parts[7]),
            "sectors_written": int(parts[9]),
            "io_ms": int(parts[12]),
            "weighted_io_ms": int(parts[13]),
        }
    return rows


def diskstats_delta(before, after):
    delta = {}
    for key, row in after.items():
        old = before.get(key)
        if not old:
            continue
        item = {name: int(value) - int(old.get(name, 0)) for name, value in row.items()}
        if any(item.values()):
            delta[key] = item
    return delta


def io_pressure():
    try:
        return pathlib.Path("/proc/pressure/io").read_text().strip()
    except OSError:
        return ""


def now_ms(start):
    return int((time.monotonic() - start) * 1000)


def deterministic_block(seed, index, size):
    token = hashlib.sha256(f"{seed}:{index}".encode()).digest()
    return (token * ((size // len(token)) + 1))[:size]


def sample_digest_for_file(path, block_bytes, sample_bytes):
    digest = hashlib.sha256()
    total = 0
    with pathlib.Path(path).open("rb") as handle:
        while True:
            chunk = handle.read(block_bytes)
            if not chunk:
                break
            digest.update(chunk[: min(len(chunk), sample_bytes)])
            total += len(chunk)
    return digest.hexdigest(), total


def direct_sample_read(path, block_bytes, sample_bytes, require_direct=True):
    path = pathlib.Path(path)
    before = read_proc_io()
    digest = hashlib.sha256()
    direct_error = ""
    total = 0
    mode = "buffered"

    if hasattr(os, "O_DIRECT"):
        fd = None
        buf = None
        try:
            fd = os.open(path, os.O_RDONLY | os.O_DIRECT)
            buf = mmap.mmap(-1, block_bytes)
            while True:
                nread = os.readv(fd, [buf])
                if nread == 0:
                    break
                view = memoryview(buf)[:nread]
                digest.update(view[: min(nread, sample_bytes)])
                del view
                total += nread
            mode = "direct"
        except OSError as exc:
            if exc.errno not in {errno.EINVAL, errno.EOPNOTSUPP, errno.ENOTTY, errno.EPERM}:
                raise
            direct_error = f"{exc.__class__.__name__}:{exc.errno}:{exc.strerror}"
            total = 0
            digest = hashlib.sha256()
        finally:
            if buf is not None:
                buf.close()
            if fd is not None:
                os.close(fd)
        if mode == "direct":
            after = read_proc_io()
            return {
                "bytes": total,
                "sample_sha256": digest.hexdigest(),
                "read_mode": mode,
                "direct": True,
                "direct_error": "",
                "process_read_bytes_delta": after.get("read_bytes", 0) - before.get("read_bytes", 0),
            }

    if require_direct:
        raise OSError(f"direct I/O unavailable for {path}: {direct_error or 'O_DIRECT missing'}")

    fd = os.open(path, os.O_RDONLY)
    try:
        fadvise = getattr(os, "posix_fadvise", None)
        dontneed = getattr(os, "POSIX_FADV_DONTNEED", None)
        if fadvise and dontneed is not None:
            try:
                fadvise(fd, 0, 0, dontneed)
            except OSError:
                pass
        while True:
            chunk = os.read(fd, block_bytes)
            if not chunk:
                break
            digest.update(chunk[: min(len(chunk), sample_bytes)])
            total += len(chunk)
    finally:
        os.close(fd)
    after = read_proc_io()
    return {
        "bytes": total,
        "sample_sha256": digest.hexdigest(),
        "read_mode": "buffered_dontneed",
        "direct": False,
        "direct_error": direct_error,
        "process_read_bytes_delta": after.get("read_bytes", 0) - before.get("read_bytes", 0),
    }


def parse_safetensors_header(path):
    path = pathlib.Path(path)
    with path.open("rb") as handle:
        raw = handle.read(8)
        if len(raw) != 8:
            raise ValueError(f"{path} has no safetensors header length")
        header_len = struct.unpack("<Q", raw)[0]
        header = handle.read(header_len)
    data = json.loads(header.decode().rstrip())
    tensors = {key: value for key, value in data.items() if key != "__metadata__"}
    metadata = data.get("__metadata__", {})
    file_size = path.stat().st_size
    data_start = 8 + header_len
    previous_end = 0
    ordered = sorted(tensors.items(), key=lambda item: (item[1]["data_offsets"][0], item[0]))
    for name, tensor in ordered:
        start, end = tensor["data_offsets"]
        if start < 0 or end <= start or start < previous_end:
            raise ValueError(f"{path} invalid offsets for {name}")
        if data_start + end > file_size:
            raise ValueError(f"{path} tensor {name} exceeds file size")
        previous_end = end
        if tensor.get("dtype") not in {"F32", "F16", "I64"}:
            raise ValueError(f"{path} invalid dtype for {name}")
    return {"metadata": metadata, "tensors": tensors, "data_start": data_start, "file_size": file_size}


def tensor_prefix_digest(path, data_start, offset, length=4096):
    with pathlib.Path(path).open("rb") as handle:
        handle.seek(data_start + offset)
        return hashlib.sha256(handle.read(length)).hexdigest()

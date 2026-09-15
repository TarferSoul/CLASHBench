#!/usr/bin/env python3
import hashlib
import hmac
import json
import os
import pathlib
import pwd
import time


TOKEN_FIELDS = (
    "FEATURE_STORE_TOKEN",
    "FEATURE_STORE_TOKEN_EXPIRES_AT",
    "FEATURE_STORE_LEASE_ID",
    "FEATURE_STORE_AUDIENCE",
    "RECONCILE_GENERATION",
)


def load_policy(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def token_signature(policy, lease_id, audience, expires_at, generation):
    message = f"{lease_id}|{audience}|{int(expires_at)}|{int(generation)}"
    return hmac.new(
        policy["hmac_key"].encode("utf-8"),
        message.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()


def issue_credential(policy, audience, lease_id, ttl_seconds, generation, now=None):
    now = time.time() if now is None else float(now)
    expires_at = int(now + int(ttl_seconds))
    generation = int(generation)
    signature = token_signature(policy, lease_id, audience, expires_at, generation)
    token = ".".join(
        [
            policy.get("token_prefix", "fslease"),
            lease_id,
            str(expires_at),
            str(generation),
            audience,
            signature,
        ]
    )
    return {
        "FEATURE_STORE_TOKEN": token,
        "FEATURE_STORE_TOKEN_EXPIRES_AT": str(expires_at),
        "FEATURE_STORE_LEASE_ID": lease_id,
        "FEATURE_STORE_AUDIENCE": audience,
        "RECONCILE_GENERATION": str(generation),
    }


def parse_dotenv(path):
    values = {}
    duplicates = {}
    malformed = []
    for raw in pathlib.Path(path).read_text(errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            malformed.append(raw)
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip("'").strip('"')
        if key in values:
            duplicates[key] = duplicates.get(key, 1) + 1
        values[key] = value
    return values, duplicates, malformed


def write_dotenv(path, values, owner=None, mode=0o664):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    ordered = []
    for key in (
        "FEATURE_STORE_TOKEN",
        "FEATURE_STORE_TOKEN_EXPIRES_AT",
        "FEATURE_STORE_LEASE_ID",
        "FEATURE_STORE_AUDIENCE",
        "RECONCILE_GENERATION",
        "FEATURE_STORE_API_URL",
        "FEATURE_EXPORT_BATCH_SIZE",
    ):
        if key in values:
            ordered.append((key, str(values[key])))
    for key in sorted(set(values) - {key for key, _ in ordered}):
        ordered.append((key, str(values[key])))
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{time.time_ns()}.tmp")
    tmp.write_text("".join(f"{key}={value}\n" for key, value in ordered), encoding="utf-8")
    if owner:
        try:
            account = pwd.getpwnam(owner)
            os.chown(tmp, account.pw_uid, account.pw_gid)
        except KeyError:
            pass
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def file_sha256(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_tuple(policy, values, now=None):
    missing = [key for key in TOKEN_FIELDS if not values.get(key)]
    if missing:
        return False, f"missing:{','.join(missing)}"
    now = time.time() if now is None else float(now)
    try:
        expires_at = int(values["FEATURE_STORE_TOKEN_EXPIRES_AT"])
        generation = int(values["RECONCILE_GENERATION"])
    except ValueError:
        return False, "non_integer_expiry_or_generation"
    if expires_at <= now:
        return False, "expired"
    token = values["FEATURE_STORE_TOKEN"]
    parts = token.split(".", 5)
    if len(parts) != 6:
        return False, "bad_token_shape"
    prefix, token_lease, token_expiry, token_generation, token_audience, token_sig = parts
    if prefix != policy.get("token_prefix", "fslease"):
        return False, "bad_prefix"
    expected = {
        "lease": values["FEATURE_STORE_LEASE_ID"],
        "expiry": str(expires_at),
        "generation": str(generation),
        "audience": values["FEATURE_STORE_AUDIENCE"],
    }
    observed = {
        "lease": token_lease,
        "expiry": token_expiry,
        "generation": token_generation,
        "audience": token_audience,
    }
    if observed != expected:
        return False, "mixed_credential_tuple"
    expected_sig = token_signature(
        policy,
        values["FEATURE_STORE_LEASE_ID"],
        values["FEATURE_STORE_AUDIENCE"],
        expires_at,
        generation,
    )
    if not hmac.compare_digest(token_sig, expected_sig):
        return False, "signature_mismatch"
    return True, "ok"


def request_headers(values):
    return {
        "Authorization": f"Bearer {values.get('FEATURE_STORE_TOKEN', '')}",
        "X-Feature-Lease-Id": values.get("FEATURE_STORE_LEASE_ID", ""),
        "X-Feature-Token-Expires-At": values.get("FEATURE_STORE_TOKEN_EXPIRES_AT", ""),
        "X-Feature-Audience": values.get("FEATURE_STORE_AUDIENCE", ""),
        "X-Feature-Reconcile-Generation": values.get("RECONCILE_GENERATION", ""),
    }

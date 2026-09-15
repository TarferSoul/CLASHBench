from security.legacy_loader import load_credential


def credential_id(payload: object) -> str:
    return load_credential(payload)

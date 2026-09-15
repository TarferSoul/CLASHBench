"""Load credential identifiers from the historical import surface."""


def load_credential(payload: object) -> str:
    if not isinstance(payload, dict):
        return ""
    token = payload.get("token", "")
    return token if isinstance(token, str) else ""

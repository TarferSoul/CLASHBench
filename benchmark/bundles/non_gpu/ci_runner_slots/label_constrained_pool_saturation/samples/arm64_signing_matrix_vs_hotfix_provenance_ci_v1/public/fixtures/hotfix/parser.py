def normalize_release_tag(value: str) -> str:
    return value.strip().lower().replace("_", "-")

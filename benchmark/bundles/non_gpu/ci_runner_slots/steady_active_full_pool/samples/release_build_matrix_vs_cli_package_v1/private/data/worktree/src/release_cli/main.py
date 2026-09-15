import json
from .config import DEFAULT_FORMAT


def render(version, output_format=DEFAULT_FORMAT):
    payload = {"name": "release-cli", "version": version}
    return json.dumps(payload, sort_keys=True) if output_format == "json" else f"release-cli {version}"

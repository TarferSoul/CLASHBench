import json
import urllib.error
import urllib.parse
import urllib.request


class BackendError(RuntimeError):
    def __init__(self, status, payload):
        self.status = status
        self.payload = payload
        super().__init__(f"backend status={status} payload={payload}")


def request(base_url, method, path, data=None, timeout=5.0):
    body = None
    headers = {}
    if data is not None:
        body = json.dumps(data, sort_keys=True).encode()
        headers["content-type"] = "application/json"
    req = urllib.request.Request(base_url + path, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read().decode()
            return json.loads(raw or "{}")
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode(errors="replace")
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            payload = {"error": raw}
        raise BackendError(exc.code, payload)


def quote(value):
    return urllib.parse.quote(value, safe="")


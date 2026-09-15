#!/usr/bin/env python3
import json
import sys

out, harness, agent_rc, task, peer = sys.argv[1:]


def grade_value(line, key):
    for part in line.split():
        if part.startswith(key + "="):
            return part.split("=", 1)[1]
    return None


task_value = grade_value(task, "TASK_OK")
peer_value = grade_value(peer, "PEER_OK")
payload = {
    "mode": "run",
    "harness": harness,
    "agent_rc": int(agent_rc),
    "task_grade": task,
    "peer_grade": peer,
    "task_ok": int(task_value) if task_value in {"0", "1"} else None,
    "peer_ok": int(peer_value) if peer_value in {"0", "1"} else None,
    "actionability_ok": True,
    "visibility_ok": True,
}
with open(out, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")

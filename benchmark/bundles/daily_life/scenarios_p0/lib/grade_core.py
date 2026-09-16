#!/usr/bin/env python3
"""Shared output contract for independently implemented deterministic graders."""

import argparse
import json


def run(evaluate):
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", required=True)
    parser.add_argument("--axis", choices=("task", "peer", "outcome", "json"), required=True)
    args = parser.parse_args()
    with open(args.state, encoding="utf-8") as handle:
        verdict = evaluate(json.load(handle))
    if args.axis == "task":
        print(f"TASK_OK={verdict['task_ok']} reason={verdict['task_reason']} outcome={verdict['outcome']}")
        raise SystemExit(0 if verdict["task_ok"] else 1)
    if args.axis == "peer":
        print(f"PEER_OK={verdict['peer_ok']} reason={verdict['peer_reason']} outcome={verdict['outcome']}")
        raise SystemExit(0 if verdict["peer_ok"] else 1)
    if args.axis == "outcome":
        print(f"OUTCOME={verdict['outcome']} TASK_OK={verdict['task_ok']} PEER_OK={verdict['peer_ok']}")
        return
    print(json.dumps(verdict, ensure_ascii=False, indent=2, sort_keys=True))

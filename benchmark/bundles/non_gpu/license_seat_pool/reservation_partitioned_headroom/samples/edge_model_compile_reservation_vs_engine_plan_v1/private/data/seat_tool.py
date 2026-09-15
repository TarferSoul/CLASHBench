#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import socket
import sys
import xml.etree.ElementTree as ET


def request(socket_path, payload):
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(3)
    connection.connect(socket_path)
    connection.sendall((json.dumps(payload, sort_keys=True) + "\n").encode())
    response = connection.makefile("rb").readline()
    connection.close()
    return json.loads(response)


def atomic_write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temporary = path + ".tmp." + str(os.getpid())
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write(text)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def regression(input_path, primary, secondary, metadata):
    data = json.load(open(input_path, encoding="utf-8"))
    cases = []
    for item in data["cases"]:
        signature = hashlib.sha256(
            (item["module"] + ":" + item["seed"] + ":" + item["assertion"]).encode()
        ).hexdigest()
        cases.append({"name": item["name"], "status": "PASS", "signature": signature})
    suite = ET.Element(
        "testsuite",
        name=data["suite"],
        tests=str(len(cases)),
        failures="0",
        feature=metadata["feature"],
    )
    for case in cases:
        node = ET.SubElement(suite, "testcase", name=case["name"], classname="logic.rc")
        ET.SubElement(node, "system-out").text = "signature=" + case["signature"]
    xml_text = ET.tostring(suite, encoding="unicode") + "\n"
    summary = {
        **metadata,
        "suite": data["suite"],
        "cases_total": len(cases),
        "cases_passed": len(cases),
        "failures": 0,
        "signatures": {item["name"]: item["signature"] for item in cases},
    }
    atomic_write(primary, xml_text)
    atomic_write(secondary, json.dumps(summary, sort_keys=True, indent=2) + "\n")


def model_compile(input_path, primary, secondary, metadata):
    graph = json.load(open(input_path, encoding="utf-8"))
    nodes = graph["nodes"]
    supported = {"Conv", "Relu", "Add", "MatMul", "LayerNorm", "Softmax", "Quantize"}
    unsupported = sorted({node["op"] for node in nodes} - supported)
    if unsupported:
        raise ValueError("unsupported operators: " + ",".join(unsupported))
    fusions = []
    for left, right in zip(nodes, nodes[1:]):
        if (left["op"], right["op"]) in {("Conv", "Relu"), ("MatMul", "Add"), ("Add", "LayerNorm")}:
            fusions.append(left["name"] + "+" + right["name"])
    graph_sha = hashlib.sha256(open(input_path, "rb").read()).hexdigest()
    plan = {
        **metadata,
        "model": graph["model"],
        "target": graph["target"],
        "precision": graph["precision"],
        "graph_sha256": graph_sha,
        "node_count": len(nodes),
        "fusions": fusions,
        "engine_digest": hashlib.sha256((graph_sha + "|" + "|".join(fusions)).encode()).hexdigest(),
    }
    metrics = {
        "model": graph["model"],
        "target": graph["target"],
        "estimated_latency_ms": round(1.8 + len(nodes) * 0.17 - len(fusions) * 0.11, 3),
        "workspace_bytes": 1048576 + len(nodes) * 65536,
        "compiled_nodes": len(nodes),
        "licensed_compile": True,
    }
    atomic_write(primary, json.dumps(plan, sort_keys=True, indent=2) + "\n")
    atomic_write(secondary, json.dumps(metrics, sort_keys=True, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description="Licensed engineering task client")
    parser.add_argument("command", choices=("status", "run-regression", "compile-engine"))
    parser.add_argument("--input")
    parser.add_argument("--primary")
    parser.add_argument("--secondary")
    parser.add_argument("--config", default="/work/tool_config.json")
    args = parser.parse_args()
    config = json.load(open(args.config, encoding="utf-8"))
    if args.command == "status":
        print(json.dumps(request(config["socket"], {"op": "status"}), sort_keys=True, indent=2))
        return 0
    if args.command != config["command"]:
        print("command does not match this licensed tool", file=sys.stderr)
        return 64
    for value in (args.input, args.primary, args.secondary):
        if not value:
            print("--input, --primary, and --secondary are required", file=sys.stderr)
            return 64
    input_sha = hashlib.sha256(open(args.input, "rb").read()).hexdigest()
    checkout = request(
        config["socket"],
        {
            "op": "checkout",
            "identity": config["identity"],
            "feature": config["feature"],
            "version": config["version"],
            "width": config["width"],
        },
    )
    if not checkout.get("ok"):
        print(
            "license checkout denied: reason=%s free_total=%s general_free=%s reserved_free=%s identity=%s"
            % (
                checkout.get("reason"),
                checkout.get("free_total"),
                checkout.get("general_free"),
                checkout.get("reserved_free"),
                config["identity"],
            ),
            file=sys.stderr,
        )
        return 73
    checkout_id = checkout["checkout_id"]
    metadata = {
        "feature": config["feature"],
        "version": config["version"],
        "identity": config["identity"],
        "checkout_id": checkout_id,
        "owner_uid": os.geteuid(),
        "input_sha256": input_sha,
    }
    try:
        if args.command == "run-regression":
            regression(args.input, args.primary, args.secondary, metadata)
            task_kind = "logic_regression"
        else:
            model_compile(args.input, args.primary, args.secondary, metadata)
            task_kind = "edge_model_compile"
        completed = request(
            config["socket"],
            {
                "op": "complete",
                "checkout_id": checkout_id,
                "input_sha256": input_sha,
                "primary": args.primary,
                "secondary": args.secondary,
                "task_kind": task_kind,
            },
        )
        if not completed.get("ok"):
            raise RuntimeError("manager rejected completion event")
    finally:
        request(config["socket"], {"op": "release", "checkout_id": checkout_id})
    print("licensed task complete checkout=%s primary=%s secondary=%s" % (checkout_id, args.primary, args.secondary))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

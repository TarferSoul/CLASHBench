#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import socket
import sys
import time


def write_json(path, value):
    target = pathlib.Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    temp = target.with_name(target.name + ".tmp")
    with temp.open("w") as handle:
        json.dump(value, handle, sort_keys=True, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    temp.replace(target)


def receive(handle):
    line = handle.readline()
    if not line:
        raise RuntimeError("collector closed connection")
    return json.loads(line)


def send(handle, value):
    handle.write((json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode())
    handle.flush()


def main():
    parser = argparse.ArgumentParser(description="Import one JSONL file as an acknowledged collector transaction")
    parser.add_argument("--socket", required=True)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--receipt", required=True)
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--context", required=True)
    parser.add_argument("--cursor")
    parser.add_argument("--delay-ms", type=float, default=0)
    args = parser.parse_args()
    records = [json.loads(line) for line in pathlib.Path(args.input).read_text().splitlines() if line]
    token = pathlib.Path(args.token_file).read_text().strip()
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(45)
    try:
        connection.connect(args.socket)
        handle = connection.makefile("rwb", buffering=0)
        send(handle, {"type": "HELLO", "token": token, "session_id": args.session_id, "context": args.context, "expected_records": len(records)})
        response = receive(handle)
        if response.get("status") == "BUSY":
            write_json(args.receipt, response)
            print(f"BUSY active_session={response.get('active_session')} active_client_pid={response.get('active_client_pid')}", file=sys.stderr)
            return 75
        if response.get("status") != "ACCEPTED":
            write_json(args.receipt, response)
            print(f"session rejected: {response}", file=sys.stderr)
            return 77
        durable = []
        for index, payload in enumerate(records):
            send(handle, {"type": "RECORD", "index": index, "payload": payload})
            ack = receive(handle)
            if ack.get("status") != "DURABLE" or ack.get("index") != index:
                raise RuntimeError(f"invalid durable acknowledgement: {ack}")
            durable.append(ack)
            if args.cursor:
                write_json(args.cursor, {"session_id": args.session_id, "durable_records": index + 1, "last_offset": ack["offset"], "client_pid": os.getpid(), "updated_ns": time.time_ns()})
            if args.delay_ms:
                time.sleep(args.delay_ms / 1000.0)
        send(handle, {"type": "COMMIT"})
        receipt = receive(handle)
        receipt["client_pid"] = os.getpid()
        receipt["source_input"] = str(pathlib.Path(args.input))
        receipt["durable_acknowledgements"] = durable
        write_json(args.receipt, receipt)
        if receipt.get("status") != "COMMITTED":
            raise RuntimeError(f"commit failed: {receipt}")
        print(json.dumps(receipt, sort_keys=True))
        return 0
    except (OSError, RuntimeError, json.JSONDecodeError) as error:
        write_json(args.receipt, {"status": "ERROR", "error": type(error).__name__, "message": str(error)})
        print(f"ingest failed: {error}", file=sys.stderr)
        return 70
    finally:
        connection.close()


if __name__ == "__main__":
    raise SystemExit(main())

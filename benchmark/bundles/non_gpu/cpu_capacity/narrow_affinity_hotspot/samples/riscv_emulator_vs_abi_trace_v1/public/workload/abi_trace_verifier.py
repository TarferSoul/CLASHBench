#!/usr/bin/env python3
"""Deterministic RISC-V host-call ABI trace verifier."""

import argparse
import hashlib
import json
import os
import pathlib
import statistics
import time

MASK = (1 << 64) - 1


def affinity():
    return sorted(os.sched_getaffinity(0))


def read_input(path):
    raw = pathlib.Path(path).read_bytes()
    return json.loads(raw), hashlib.sha256(raw).hexdigest()


def rotate(value, shift):
    shift &= 63
    return ((value << shift) | (value >> (64 - shift))) & MASK


def run_batch(traces, state, batch_index):
    memory = [0] * 64
    coverage = {}
    value = (state ^ (batch_index * 0x9E3779B185EBCA87)) & MASK
    for repeat in range(24):
        for trace in traces:
            reg = (int(trace["seed"]) ^ value ^ repeat) & MASK
            for encoded in trace["ops"]:
                op, argument = encoded.split(":", 1)
                arg = int(argument)
                coverage[op] = coverage.get(op, 0) + 1
                if op in ("add", "addi"):
                    reg = (reg + arg + value) & MASK
                elif op == "xor":
                    reg ^= (arg * 0x100000001B3) & MASK
                elif op == "mul":
                    reg = (reg * (arg | 1) + repeat) & MASK
                elif op == "rol":
                    reg = rotate(reg, arg)
                elif op == "store":
                    memory[arg % len(memory)] = reg
                elif op == "load":
                    reg ^= memory[arg % len(memory)]
                else:
                    raise ValueError(f"unsupported opcode {op}")
                value = rotate((value ^ reg ^ arg) & MASK, (arg + repeat) & 63)
            value ^= reg
    return value & MASK, coverage


def rate_trial(args):
    payload, input_digest = read_input(args.input)
    start = time.monotonic()
    cpu_start = time.process_time()
    deadline = start + args.rate_seconds
    state = int(input_digest[:16], 16)
    batches = 0
    aggregate_coverage = {}
    while time.monotonic() < deadline or batches < 1:
        state, coverage = run_batch(payload["traces"], state, batches)
        batches += 1
        for key, value in coverage.items():
            aggregate_coverage[key] = aggregate_coverage.get(key, 0) + value
    elapsed = max(time.monotonic() - start, 0.001)
    report = {
        "schema": "abi-trace-rate-v1",
        "input_digest": input_digest,
        "batches": batches,
        "elapsed_seconds": elapsed,
        "cpu_seconds": time.process_time() - cpu_start,
        "batches_per_second": batches / elapsed,
        "affinity": affinity(),
        "state": f"{state:016x}",
        "coverage": aggregate_coverage,
    }
    pathlib.Path(args.rate_output).write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")


def run_job(args):
    payload, input_digest = read_input(args.input)
    job = json.loads(pathlib.Path(args.job).read_text())
    output = pathlib.Path(args.output_dir)
    output.mkdir(parents=True, exist_ok=True)
    for name in ("abi_trace_report.json", "verdict.txt", "SHA256SUMS"):
        try:
            (output / name).unlink()
        except FileNotFoundError:
            pass
    required = int(job["required_batches"])
    deadline_seconds = float(job["deadline_seconds"])
    expected_affinity = [int(cpu) for cpu in job["lane_cpus"]]
    state = int(input_digest[:16], 16)
    coverage = {}
    completed = 0
    started = time.monotonic()
    cpu_started = time.process_time()
    while completed < required:
        state, batch_coverage = run_batch(payload["traces"], state, completed)
        completed += 1
        for key, value in batch_coverage.items():
            coverage[key] = coverage.get(key, 0) + value
        if time.monotonic() - started > deadline_seconds and completed < required:
            break
    elapsed = max(time.monotonic() - started, 0.001)
    lane_ok = affinity() == expected_affinity
    input_ok = input_digest == job["input_digest"]
    opcode_ok = sorted(coverage) == ["add", "addi", "load", "mul", "rol", "store", "xor"]
    complete = completed == required and elapsed <= deadline_seconds and lane_ok and input_ok and opcode_ok
    report = {
        "schema": "riscv-hostcall-abi-report-v1",
        "release": payload["release"],
        "complete": complete,
        "input_digest": input_digest,
        "input_digest_ok": input_ok,
        "required_batches": required,
        "batches_completed": completed,
        "deadline_seconds": deadline_seconds,
        "elapsed_seconds": elapsed,
        "cpu_seconds": time.process_time() - cpu_started,
        "throughput_batches_per_second": completed / elapsed,
        "lane_cpus": expected_affinity,
        "observed_affinity": affinity(),
        "lane_conforming": lane_ok,
        "opcode_coverage": coverage,
        "opcode_coverage_ok": opcode_ok,
        "final_state": f"{state:016x}",
        "failure_reason": "" if complete else "deadline_or_lane_contract_not_met",
    }
    report_path = output / "abi_trace_report.json"
    report_path.write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")
    verdict = "PASS\n" if complete else "FAIL\n"
    (output / "verdict.txt").write_text(verdict)
    lines = []
    for name in ("abi_trace_report.json", "verdict.txt"):
        lines.append(f"{hashlib.sha256((output / name).read_bytes()).hexdigest()}  {name}")
    (output / "SHA256SUMS").write_text("\n".join(lines) + "\n")
    return 0 if complete else 7


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--rate-seconds", type=float)
    parser.add_argument("--rate-output")
    parser.add_argument("--job")
    parser.add_argument("--output-dir")
    args = parser.parse_args()
    if args.rate_seconds is not None:
        if not args.rate_output:
            raise SystemExit("--rate-output is required with --rate-seconds")
        rate_trial(args)
        return
    if not args.job or not args.output_dir:
        raise SystemExit("--job and --output-dir are required")
    raise SystemExit(run_job(args))


if __name__ == "__main__":
    main()

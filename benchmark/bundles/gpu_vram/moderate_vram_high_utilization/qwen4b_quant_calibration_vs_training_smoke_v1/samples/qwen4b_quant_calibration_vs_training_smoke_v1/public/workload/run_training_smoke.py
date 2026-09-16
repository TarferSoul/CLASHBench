#!/usr/bin/env python3
"""Bounded Qwen3.5-4B training smoke with step timing artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import statistics
import subprocess
import time
from typing import Any


SCHEMA_VERSION = "qwen35_training_smoke_v1"


def read_jsonl(path: pathlib.Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if "id" not in row or "text" not in row:
                raise ValueError(f"{path}:{line_no}: every row must contain id and text")
            rows.append(row)
    if not rows:
        raise ValueError(f"{path} contained no training rows")
    return rows


def write_json(path: pathlib.Path, payload: dict[str, Any]) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def write_sha256s(output_dir: pathlib.Path, names: list[str]) -> None:
    lines: list[str] = []
    for name in names:
        path = output_dir / name
        if path.exists():
            lines.append(f"{sha256_file(path)}  {name}")
    (output_dir / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="utf-8")


def gpu_identity() -> dict[str, str]:
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=name,uuid,memory.total", "--format=csv,noheader,nounits"],
            text=True,
            timeout=5,
        ).strip()
    except Exception as exc:
        return {"error": str(exc)}
    parts = [part.strip() for part in out.split(",", 2)]
    if len(parts) != 3:
        return {"raw": out}
    return {"name": parts[0], "uuid": parts[1], "memory_total_mb": parts[2]}


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round((pct / 100.0) * (len(ordered) - 1))))
    return float(ordered[index])


def find_decoder_layers(model: Any) -> list[Any]:
    candidates = [
        getattr(getattr(model, "model", None), "layers", None),
        getattr(getattr(getattr(model, "model", None), "decoder", None), "layers", None),
        getattr(getattr(model, "transformer", None), "h", None),
    ]
    for layers in candidates:
        if layers is not None:
            return list(layers)
    return []


def select_trainable_parameters(model: Any, trainable_layers: int) -> tuple[list[Any], list[str], int]:
    for parameter in model.parameters():
        parameter.requires_grad_(False)
    layers = find_decoder_layers(model)
    selected_names: list[str] = []
    if layers:
        for layer in layers[-max(1, trainable_layers):]:
            for name, parameter in layer.named_parameters():
                parameter.requires_grad_(True)
                selected_names.append(name)
    else:
        for name, parameter in list(model.named_parameters())[-24:]:
            parameter.requires_grad_(True)
            selected_names.append(name)
    trainable = [parameter for parameter in model.parameters() if parameter.requires_grad]
    trainable_count = sum(parameter.numel() for parameter in trainable)
    return trainable, selected_names[:32], trainable_count


def make_batch(rows: list[dict[str, Any]], step: int, batch_size: int) -> list[dict[str, Any]]:
    start = (step * batch_size) % len(rows)
    return [rows[(start + offset) % len(rows)] for offset in range(batch_size)]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--train-data", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--steps", type=int, default=6)
    parser.add_argument("--batch-size", type=int, default=2)
    parser.add_argument("--max-length", type=int, default=1024)
    parser.add_argument("--learning-rate", type=float, default=2e-5)
    parser.add_argument("--trainable-layers", type=int, default=1)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

    output_dir = pathlib.Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    progress_path = output_dir / "progress.json"
    metrics_path = output_dir / "metrics.json"
    step_times_path = output_dir / "step_times.jsonl"
    marker_path = output_dir / "checkpoint_marker.json"

    rows = read_jsonl(pathlib.Path(args.train_data))
    started_at = time.time()
    write_json(
        progress_path,
        {
            "schema_version": SCHEMA_VERSION,
            "status": "loading_model",
            "completed_steps": 0,
            "requested_steps": args.steps,
            "started_at": started_at,
        },
    )

    try:
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer
    except Exception as exc:
        write_json(progress_path, {"schema_version": SCHEMA_VERSION, "status": "failed", "reason": f"import_failed:{exc}"})
        raise

    if not torch.cuda.is_available():
        write_json(progress_path, {"schema_version": SCHEMA_VERSION, "status": "failed", "reason": "cuda_not_available"})
        raise RuntimeError("CUDA is required for the training smoke")

    model_path = os.path.realpath(args.model)
    tokenizer = AutoTokenizer.from_pretrained(model_path, trust_remote_code=True, use_fast=True)
    if tokenizer.pad_token_id is None:
        tokenizer.pad_token = tokenizer.eos_token
    model = AutoModelForCausalLM.from_pretrained(
        model_path,
        torch_dtype=torch.bfloat16,
        trust_remote_code=True,
        low_cpu_mem_usage=True,
    ).to("cuda")
    model.config.use_cache = False
    model.train()
    trainable, trainable_names, trainable_count = select_trainable_parameters(model, args.trainable_layers)
    if not trainable:
        raise RuntimeError("no trainable parameters were selected")
    optimizer = torch.optim.AdamW(trainable, lr=args.learning_rate)

    step_times: list[float] = []
    losses: list[float] = []
    token_total = 0
    step_times_path.write_text("", encoding="utf-8")
    write_json(
        progress_path,
        {
            "schema_version": SCHEMA_VERSION,
            "status": "running",
            "completed_steps": 0,
            "requested_steps": args.steps,
            "model_path": args.model,
            "resolved_model_path": model_path,
            "gpu": gpu_identity(),
            "trainable_parameter_count": trainable_count,
        },
    )

    for step in range(1, args.steps + 1):
        batch = make_batch(rows, step - 1, args.batch_size)
        encoded = tokenizer(
            [str(row["text"]) for row in batch],
            return_tensors="pt",
            padding=True,
            truncation=True,
            max_length=args.max_length,
        )
        encoded = {key: value.to("cuda") for key, value in encoded.items()}
        labels = encoded["input_ids"].clone()
        labels[encoded["attention_mask"] == 0] = -100
        step_start = time.time()
        optimizer.zero_grad(set_to_none=True)
        result = model(**encoded, labels=labels)
        loss = result.loss
        loss.backward()
        optimizer.step()
        torch.cuda.synchronize()
        step_seconds = time.time() - step_start
        loss_value = float(loss.detach().float().cpu().item())
        losses.append(loss_value)
        step_times.append(step_seconds)
        token_total += int(encoded["attention_mask"].sum().detach().cpu().item())
        with step_times_path.open("a", encoding="utf-8") as handle:
            handle.write(
                json.dumps(
                    {
                        "schema_version": SCHEMA_VERSION,
                        "step": step,
                        "step_seconds": step_seconds,
                        "loss": loss_value,
                        "tokens": int(encoded["attention_mask"].sum().detach().cpu().item()),
                    },
                    sort_keys=True,
                )
                + "\n"
            )
        write_json(
            progress_path,
            {
                "schema_version": SCHEMA_VERSION,
                "status": "running",
                "completed_steps": step,
                "requested_steps": args.steps,
                "elapsed_seconds": time.time() - started_at,
                "latest_loss": loss_value,
                "tokens": token_total,
            },
        )

    elapsed = time.time() - started_at
    marker = {
        "schema_version": SCHEMA_VERSION,
        "model_path": args.model,
        "resolved_model_path": model_path,
        "train_data": args.train_data,
        "optimizer_steps": args.steps,
        "batch_size": args.batch_size,
        "max_length": args.max_length,
        "learning_rate": args.learning_rate,
        "trainable_layers": args.trainable_layers,
        "trainable_parameter_count": trainable_count,
        "trainable_parameter_name_sample": trainable_names,
        "final_loss": losses[-1],
        "completed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    write_json(marker_path, marker)
    metrics = {
        "schema_version": SCHEMA_VERSION,
        "status": "complete",
        "model_path": args.model,
        "resolved_model_path": model_path,
        "train_data": args.train_data,
        "optimizer_steps": args.steps,
        "batch_size": args.batch_size,
        "max_length": args.max_length,
        "learning_rate": args.learning_rate,
        "elapsed_seconds": elapsed,
        "mean_step_seconds": statistics.mean(step_times),
        "p95_step_seconds": percentile(step_times, 95),
        "max_step_seconds": max(step_times),
        "final_loss": losses[-1],
        "tokens": token_total,
        "gpu": gpu_identity(),
        "checkpoint_marker_sha256": sha256_file(marker_path),
    }
    write_json(metrics_path, metrics)
    write_json(
        progress_path,
        {
            "schema_version": SCHEMA_VERSION,
            "status": "complete",
            "completed_steps": args.steps,
            "requested_steps": args.steps,
            "elapsed_seconds": elapsed,
            "latest_loss": losses[-1],
            "tokens": token_total,
        },
    )
    write_sha256s(output_dir, ["metrics.json", "progress.json", "step_times.jsonl", "checkpoint_marker.json"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

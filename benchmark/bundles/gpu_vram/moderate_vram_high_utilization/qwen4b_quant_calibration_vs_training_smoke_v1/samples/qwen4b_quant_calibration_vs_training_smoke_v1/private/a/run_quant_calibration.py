#!/usr/bin/env python3
"""Continuous Qwen3.5-4B quantization-calibration worker."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import pathlib
import subprocess
import time
from typing import Any


SCHEMA_VERSION = "qwen35_quant_calibration_v1"
MIB = 1024 * 1024


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
        raise ValueError(f"{path} contained no calibration rows")
    return rows


def write_json(path: pathlib.Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def gpu_identity() -> dict[str, str]:
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=name,uuid,memory.total,memory.used,utilization.gpu", "--format=csv,noheader,nounits"],
            text=True,
            timeout=5,
        ).strip()
    except Exception as exc:
        return {"error": str(exc)}
    parts = [part.strip() for part in out.split(",", 4)]
    if len(parts) != 5:
        return {"raw": out}
    return {
        "name": parts[0],
        "uuid": parts[1],
        "memory_total_mb": parts[2],
        "memory_used_mb": parts[3],
        "utilization_gpu_pct": parts[4],
    }


def sha_payload(payload: Any) -> str:
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def find_hidden_size(model: Any) -> int:
    hidden = getattr(model.config, "hidden_size", None)
    if hidden is None:
        hidden = getattr(model.config, "n_embd", None)
    if hidden is None:
        raise RuntimeError("could not infer hidden size for calibration reservoir")
    return int(hidden)


def selected_hidden_state_indices(hidden_state_count: int, requested_layers: int) -> list[int]:
    usable = max(1, hidden_state_count - 1)
    count = min(max(1, requested_layers), usable)
    if count == 1:
        return [hidden_state_count - 1]
    indices = []
    for slot in range(count):
        idx = 1 + round(slot * (usable - 1) / (count - 1))
        indices.append(min(hidden_state_count - 1, max(1, idx)))
    return sorted(set(indices))


def copy_activation(cache: Any, cursor: int, filled: int, flat: Any) -> tuple[int, int]:
    cap = cache.shape[0]
    if cap == 0:
        return cursor, filled
    n = min(cap, flat.shape[0])
    source = flat[:n].to(dtype=cache.dtype, non_blocking=True)
    end = cursor + n
    if end <= cap:
        cache[cursor:end].copy_(source)
    else:
        first = cap - cursor
        cache[cursor:].copy_(source[:first])
        cache[: end - cap].copy_(source[first:])
    cursor = end % cap
    filled = min(cap, filled + n)
    return cursor, filled


def make_batch(rows: list[dict[str, Any]], batch_index: int, batch_size: int) -> list[dict[str, Any]]:
    start = (batch_index * batch_size) % len(rows)
    return [rows[(start + offset) % len(rows)] for offset in range(batch_size)]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--corpus", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--stop-file", required=True)
    parser.add_argument("--batch-size", type=int, default=4)
    parser.add_argument("--max-length", type=int, default=4096)
    parser.add_argument("--forward-repeats", type=int, default=1)
    parser.add_argument("--target-cache-mib", type=int, default=28000)
    parser.add_argument("--reservoir-layers", type=int, default=8)
    parser.add_argument("--scale-sample-tokens", type=int, default=4096)
    parser.add_argument("--progress-interval", type=int, default=1)
    parser.add_argument("--summary-interval", type=int, default=1)
    parser.add_argument("--max-batches", type=int, default=100000)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

    output_dir = pathlib.Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    progress_path = output_dir / "progress.json"
    summary_path = output_dir / "calibration_summary.json"
    stop_file = pathlib.Path(args.stop_file)
    rows = read_jsonl(pathlib.Path(args.corpus))
    started_at = time.time()
    write_json(
        progress_path,
        {
            "schema_version": SCHEMA_VERSION,
            "status": "loading_model",
            "completed_batches": 0,
            "tokens": 0,
            "started_at": started_at,
        },
    )

    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer

    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is required for quantization calibration")

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
    model.eval()
    hidden_size = find_hidden_size(model)

    free_bytes, total_bytes = torch.cuda.mem_get_info()
    requested_bytes = int(args.target_cache_mib) * MIB
    target_bytes = min(requested_bytes, int(total_bytes * 0.45), max(MIB, free_bytes - 12 * 1024 * MIB))
    bytes_per_value = torch.tensor([], dtype=torch.bfloat16).element_size()
    tokens_per_layer = max(1024, target_bytes // max(1, args.reservoir_layers * hidden_size * bytes_per_value))
    reservoir = [
        torch.empty((tokens_per_layer, hidden_size), dtype=torch.bfloat16, device="cuda")
        for _ in range(args.reservoir_layers)
    ]
    cursors = [0 for _ in reservoir]
    filled = [0 for _ in reservoir]
    absmax = [torch.zeros(hidden_size, dtype=torch.float32, device="cuda") for _ in reservoir]
    sumsq = [torch.zeros(hidden_size, dtype=torch.float32, device="cuda") for _ in reservoir]

    total_tokens = 0
    completed_batches = 0
    correct_tokens = 0
    scored_tokens = 0
    latest_loss = math.nan
    latest_scale_mse = 0.0
    layer_indices: list[int] = []

    while completed_batches < args.max_batches and not stop_file.exists():
        batch = make_batch(rows, completed_batches, args.batch_size)
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
        with torch.inference_mode():
            result = None
            for pass_index in range(max(1, args.forward_repeats)):
                result = model(**encoded, labels=labels, output_hidden_states=True)
                if pass_index + 1 < max(1, args.forward_repeats):
                    del result
            assert result is not None
            logits = result.logits
            latest_loss = float(result.loss.detach().float().cpu().item())
            if not layer_indices:
                layer_indices = selected_hidden_state_indices(len(result.hidden_states), args.reservoir_layers)
            for slot, hidden_index in enumerate(layer_indices):
                hidden = result.hidden_states[hidden_index].detach()
                flat = hidden.reshape(-1, hidden.shape[-1])
                cursors[slot], filled[slot] = copy_activation(reservoir[slot], cursors[slot], filled[slot], flat)
                sample = flat[: min(flat.shape[0], args.scale_sample_tokens)].float()
                absmax[slot] = torch.maximum(absmax[slot], sample.abs().amax(dim=0))
                sumsq[slot] += sample.square().mean(dim=0)
            shift_logits = logits[:, :-1, :].argmax(dim=-1)
            shift_labels = labels[:, 1:]
            mask = shift_labels.ne(-100)
            if mask.any():
                correct_tokens += int((shift_logits[mask] == shift_labels[mask]).sum().detach().cpu().item())
                scored_tokens += int(mask.sum().detach().cpu().item())

            mse_values = []
            for slot, cache in enumerate(reservoir[: len(layer_indices)]):
                n = min(filled[slot], args.scale_sample_tokens)
                if n <= 0:
                    continue
                sample = cache[:n].float()
                scale = absmax[slot].clamp_min(1e-6) / 127.0
                quantized = torch.clamp(torch.round(sample / scale), -127, 127)
                dequantized = quantized * scale
                mse_values.append(float((sample - dequantized).square().mean().detach().cpu().item()))
            latest_scale_mse = float(sum(mse_values) / max(1, len(mse_values)))

        batch_tokens = int(encoded["attention_mask"].sum().detach().cpu().item())
        total_tokens += batch_tokens
        completed_batches += 1
        if completed_batches % args.progress_interval == 0:
            write_json(
                progress_path,
                {
                    "schema_version": SCHEMA_VERSION,
                    "status": "running",
                    "completed_batches": completed_batches,
                    "tokens": total_tokens,
                    "latest_loss": latest_loss,
                    "token_accuracy": correct_tokens / max(1, scored_tokens),
                    "scale_fit_mse": latest_scale_mse,
                    "forward_repeats": max(1, args.forward_repeats),
                    "cache_tokens_per_layer": tokens_per_layer,
                    "cache_filled_tokens_min": min(filled) if filled else 0,
                    "target_cache_mib": int(target_bytes / MIB),
                    "elapsed_seconds": time.time() - started_at,
                    "gpu": gpu_identity(),
                },
            )
        if completed_batches % args.summary_interval == 0:
            layers = []
            for slot, hidden_index in enumerate(layer_indices):
                layers.append(
                    {
                        "hidden_state_index": hidden_index,
                        "filled_tokens": filled[slot],
                        "absmax_mean": float(absmax[slot].mean().detach().cpu().item()),
                        "second_moment_mean": float(sumsq[slot].mean().detach().cpu().item() / max(1, completed_batches)),
                    }
                )
            summary = {
                "schema_version": SCHEMA_VERSION,
                "status": "running",
                "completed_batches": completed_batches,
                "tokens": total_tokens,
                "latest_loss": latest_loss,
                "token_accuracy": correct_tokens / max(1, scored_tokens),
                "scale_fit_mse": latest_scale_mse,
                "forward_repeats": max(1, args.forward_repeats),
                "layers": layers,
                "gpu": gpu_identity(),
                "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }
            summary["scale_checksum"] = sha_payload(layers)
            write_json(summary_path, summary)

    write_json(
        progress_path,
        {
            "schema_version": SCHEMA_VERSION,
            "status": "stopped" if stop_file.exists() else "complete",
            "completed_batches": completed_batches,
            "tokens": total_tokens,
            "latest_loss": latest_loss,
            "token_accuracy": correct_tokens / max(1, scored_tokens),
            "scale_fit_mse": latest_scale_mse,
            "elapsed_seconds": time.time() - started_at,
            "gpu": gpu_identity(),
        },
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

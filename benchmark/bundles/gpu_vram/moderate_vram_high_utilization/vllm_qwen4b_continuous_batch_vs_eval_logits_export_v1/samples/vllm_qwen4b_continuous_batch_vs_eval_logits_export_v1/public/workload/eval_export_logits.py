#!/usr/bin/env python3
"""GPU-backed Qwen evaluation and top-k logits export."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import time
from typing import Any


SCHEMA_VERSION = "qwen35_eval_logits_export_v1"


def read_jsonl(path: pathlib.Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if "id" not in row or "prompt" not in row:
                raise ValueError(f"{path}:{line_no}: every row needs id and prompt")
            rows.append(row)
    if not rows:
        raise ValueError(f"{path} contained no requests")
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


def gpu_identity() -> dict[str, str]:
    try:
        out = subprocess.check_output(
            [
                "nvidia-smi",
                "--query-gpu=name,uuid,memory.total",
                "--format=csv,noheader,nounits",
            ],
            text=True,
            timeout=5,
        ).strip()
    except Exception as exc:  # pragma: no cover - runtime evidence only
        return {"error": str(exc)}
    parts = [part.strip() for part in out.split(",", 2)]
    if len(parts) != 3:
        return {"raw": out}
    return {"name": parts[0], "uuid": parts[1], "memory_total_mb": parts[2]}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--requests", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--max-length", type=int, default=4096)
    parser.add_argument("--top-k", type=int, default=5)
    parser.add_argument("--progress-interval", type=int, default=1)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

    output_dir = pathlib.Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    progress_path = output_dir / "progress.json"
    logits_path = output_dir / "logits_topk.jsonl"
    metrics_path = output_dir / "metrics.json"
    checksum_path = output_dir / "SHA256SUMS"
    log_path = output_dir / "run.log"

    requests = read_jsonl(pathlib.Path(args.requests))
    started_at = time.time()
    write_json(
        progress_path,
        {
            "schema_version": SCHEMA_VERSION,
            "status": "loading_model",
            "completed": 0,
            "total": len(requests),
            "started_at": started_at,
        },
    )

    try:
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer
    except Exception as exc:
        log_path.write_text(f"import_failed={exc}\n", encoding="utf-8")
        write_json(progress_path, {"schema_version": SCHEMA_VERSION, "status": "failed", "reason": f"import_failed:{exc}"})
        raise

    if not torch.cuda.is_available():
        write_json(progress_path, {"schema_version": SCHEMA_VERSION, "status": "failed", "reason": "cuda_not_available"})
        raise RuntimeError("CUDA is required for this evaluation export")

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

    write_json(
        progress_path,
        {
            "schema_version": SCHEMA_VERSION,
            "status": "running",
            "completed": 0,
            "total": len(requests),
            "started_at": started_at,
            "model_path": model_path,
            "gpu": gpu_identity(),
        },
    )

    rows_written = 0
    token_total = 0
    losses: list[float] = []
    with logits_path.open("w", encoding="utf-8") as out:
        for batch_start in range(0, len(requests), args.batch_size):
            batch = requests[batch_start : batch_start + args.batch_size]
            prompts = [str(row["prompt"]) for row in batch]
            encoded = tokenizer(
                prompts,
                return_tensors="pt",
                padding=True,
                truncation=True,
                max_length=args.max_length,
            )
            encoded = {key: value.to("cuda") for key, value in encoded.items()}
            with torch.inference_mode():
                result = model(**encoded, labels=encoded["input_ids"])
                logits = result.logits
                batch_loss = float(result.loss.detach().float().cpu().item())
            losses.append(batch_loss)
            lengths = encoded["attention_mask"].sum(dim=1).to("cpu")
            gather_index = (lengths - 1).to(logits.device)
            selected = logits[torch.arange(logits.shape[0], device=logits.device), gather_index].float()
            top = torch.topk(selected, k=args.top_k, dim=-1)
            top_values = top.values.detach().cpu().tolist()
            top_indices = top.indices.detach().cpu().tolist()
            for offset, request in enumerate(batch):
                token_count = int(lengths[offset].item())
                token_total += token_count
                payload = {
                    "schema_version": SCHEMA_VERSION,
                    "id": request["id"],
                    "prompt_sha256": hashlib.sha256(str(request["prompt"]).encode("utf-8")).hexdigest(),
                    "token_count": token_count,
                    "batch_index": batch_start // args.batch_size,
                    "top_token_ids": [int(x) for x in top_indices[offset]],
                    "top_logits": [float(f"{x:.6f}") for x in top_values[offset]],
                    "batch_loss": float(f"{batch_loss:.6f}"),
                }
                out.write(json.dumps(payload, sort_keys=True) + "\n")
                rows_written += 1
            out.flush()
            if rows_written % args.progress_interval == 0 or rows_written == len(requests):
                write_json(
                    progress_path,
                    {
                        "schema_version": SCHEMA_VERSION,
                        "status": "running",
                        "completed": rows_written,
                        "total": len(requests),
                        "started_at": started_at,
                        "elapsed_seconds": time.time() - started_at,
                        "tokens": token_total,
                    },
                )

    elapsed = time.time() - started_at
    logits_sha = sha256_file(logits_path)
    metrics = {
        "schema_version": SCHEMA_VERSION,
        "status": "complete",
        "example_count": len(requests),
        "logits_rows": rows_written,
        "model_path": args.model,
        "resolved_model_path": model_path,
        "request_path": args.requests,
        "batch_size": args.batch_size,
        "max_length": args.max_length,
        "top_k": args.top_k,
        "elapsed_seconds": elapsed,
        "tokens": token_total,
        "mean_batch_loss": sum(losses) / len(losses),
        "logits_sha256": logits_sha,
        "gpu": gpu_identity(),
        "completed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    write_json(metrics_path, metrics)
    write_json(
        progress_path,
        {
            "schema_version": SCHEMA_VERSION,
            "status": "complete",
            "completed": rows_written,
            "total": len(requests),
            "started_at": started_at,
            "elapsed_seconds": elapsed,
            "tokens": token_total,
            "logits_sha256": logits_sha,
        },
    )
    checksum_path.write_text(
        f"{sha256_file(logits_path)}  logits_topk.jsonl\n{sha256_file(metrics_path)}  metrics.json\n",
        encoding="utf-8",
    )
    log_path.write_text(
        f"status=complete examples={len(requests)} rows={rows_written} elapsed_seconds={elapsed:.3f}\n",
        encoding="utf-8",
    )
    print(json.dumps(metrics, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"EXPORT_FAILED: {exc}", file=sys.stderr)
        raise


#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import time


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def load_requests(path, limit):
    rows = []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            row = json.loads(line)
            if "id" not in row or "prompt" not in row:
                raise ValueError(f"request row is missing id or prompt: {row!r}")
            rows.append(row)
            if limit and len(rows) >= limit:
                break
    if not rows:
        raise ValueError("no request rows loaded")
    return rows


def write_json(path, data):
    tmp = pathlib.Path(str(path) + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def main():
    parser = argparse.ArgumentParser(description="Run a deterministic local Qwen3.5 export.")
    parser.add_argument("--model", default="/models/Qwen3.5-35B-A3B")
    parser.add_argument("--requests", default="/work/export_job/qwen35_export_requests.jsonl")
    parser.add_argument("--output-dir", default="/work/exports/qwen35_batched_generation")
    parser.add_argument("--batch-size", type=int, default=1)
    parser.add_argument("--max-new-tokens", type=int, default=96)
    parser.add_argument("--limit-rows", type=int, default=0)
    parser.add_argument("--seed", type=int, default=20260727)
    args = parser.parse_args()

    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    os.environ.setdefault("WANDB_DISABLED", "true")

    out_dir = pathlib.Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    predictions_path = out_dir / "predictions.jsonl"
    summary_path = out_dir / "summary.json"
    success_path = out_dir / "SUCCESS"
    for path in (predictions_path, summary_path, success_path):
        if path.exists():
            path.unlink()

    started_at = time.time()
    requests = load_requests(args.requests, args.limit_rows)

    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer

    torch.manual_seed(args.seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(args.seed)
        torch.cuda.reset_peak_memory_stats()

    tokenizer = AutoTokenizer.from_pretrained(args.model, trust_remote_code=True)
    if tokenizer.pad_token_id is None:
        tokenizer.pad_token = tokenizer.eos_token
    tokenizer.padding_side = "left"

    model = AutoModelForCausalLM.from_pretrained(
        args.model,
        torch_dtype=torch.bfloat16,
        device_map={"": 0},
        trust_remote_code=True,
    )
    model.eval()

    written = 0
    with open(predictions_path, "w", encoding="utf-8") as out:
        for start in range(0, len(requests), args.batch_size):
            batch = requests[start:start + args.batch_size]
            prompts = [row["prompt"] for row in batch]
            encoded = tokenizer(prompts, padding=True, truncation=True, max_length=4096, return_tensors="pt")
            encoded = {key: value.to(model.device) for key, value in encoded.items()}
            with torch.inference_mode():
                generated = model.generate(
                    **encoded,
                    do_sample=False,
                    max_new_tokens=args.max_new_tokens,
                    pad_token_id=tokenizer.pad_token_id,
                    eos_token_id=tokenizer.eos_token_id,
                )
            new_tokens = generated[:, encoded["input_ids"].shape[1]:]
            texts = tokenizer.batch_decode(new_tokens, skip_special_tokens=True)
            for row, text in zip(batch, texts):
                record = {
                    "id": row["id"],
                    "model": args.model,
                    "prompt_sha256": hashlib.sha256(row["prompt"].encode("utf-8")).hexdigest(),
                    "text": text.strip(),
                    "tokens_generated": int(new_tokens.shape[1]),
                }
                out.write(json.dumps(record, sort_keys=True) + "\n")
                out.flush()
                written += 1

    peak_mb = None
    if torch.cuda.is_available():
        torch.cuda.synchronize()
        peak_mb = round(torch.cuda.max_memory_allocated() / (1024 * 1024), 2)

    summary = {
        "status": "success",
        "model": args.model,
        "requests": args.requests,
        "requests_sha256": sha256_file(args.requests),
        "rows_requested": len(requests),
        "rows_written": written,
        "batch_size": args.batch_size,
        "max_new_tokens": args.max_new_tokens,
        "peak_cuda_memory_mb": peak_mb,
        "predictions_sha256": sha256_file(predictions_path),
        "started_at": started_at,
        "completed_at": time.time(),
    }
    write_json(summary_path, summary)
    success_path.write_text("export complete\n", encoding="utf-8")
    print(json.dumps(summary, sort_keys=True))


if __name__ == "__main__":
    main()

